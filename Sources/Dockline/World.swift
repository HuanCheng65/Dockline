import AppKit
import DocklineCore
import SwiftUI

/// 诊断读数。独立成一个对象，是因为它每 2 秒都会变，而 bar 不该为它重绘——
/// 重绘会打断正在进行的隐式动画（图标弹跳因此一顿一顿的）。只有设置窗口观察它。
final class Diagnostics: ObservableObject {
    @Published var timing = IndexTiming()
    @Published var events = 0
    @Published var watchedProcesses = 0
    /// 尚未拿到 AX 引用的窗口数——它们只能靠通道三兜底，是覆盖率的直接指标
    @Published var unclaimedWindows = 0
    /// 重试用尽仍未订阅成功的进程数
    @Published var unobservedProcesses = 0
}

/// 三通道汇流点，以及所有与「哪块屏」无关的状态。
///  · 通道一 NSWorkspace：App 启动 / 退出 / 激活
///  · 通道二 AXObserver：窗口创建 / 销毁 / 标题变更 / 最小化 / 取消最小化（低延迟主通道）
///  · 通道三 CG 对账：定期兜底存在性——AX 通知在 Electron 系 App 上确有漏报
///
/// 计划书 §6 M5 把 bar 拆成每块显示器一条，于是原来那一个 BarModel 里混着两种东西：
/// 窗口索引、固定项、编组、顺序、活动状态是全局唯一的，而版面、溢出、明暗、隐藏
/// 是每条 bar 各自的。前者留在这里，后者归 `BarModel`——**对象全局，交互就地**。
final class World: ObservableObject {
    @Published private(set) var windows: [IndexedWindow] = []
    @Published var accessibility = false { didSet { rebuild() } }
    @Published var screenRecording = false { didSet { rebuild() } }
    /// 当前前台窗口——底色「亮底」档的唯一依据
    @Published private(set) var frontWindow: CGWindowID?
    /// 正在启动的 App。系统 Dock 用图标弹跳表示「点到了，正在开」——
    /// 开一个 App 到窗口出现有好几秒，没有反馈时用户会以为没点上。
    @Published private(set) var launching: Set<String> = []
    /// 每个正在弹跳的 App 的起跳时刻与「已排好落地」标记，供 `landBounce` 对齐轮次
    private var bounceStarted: [String: Date] = [:]
    private var landing: Set<String> = []
    /// 图标尺寸。缺省跟随系统程序坞，用户可拖分隔线或在设置中调整。
    @Published var iconSize: CGFloat = BarMetrics.iconFull {
        didSet { BarMetrics.iconFull = iconSize }
    }
    /// 未读角标，按 bundle ID。只在真的变了才发布，否则每 2 秒一次的读取会
    /// 把整条 bar 重绘一遍，打断动画。
    @Published private(set) var badges: [String: String] = [:]
    /// 活动状态，按上报进程。计划书 §3。
    @Published private(set) var activities: [pid_t: Activity] = [:]

    let pins = PinStore()
    let clusters = ClusterStore()
    /// 每个 App 最后一次拥有窗口时，那个窗口在哪块屏。窗口全关之后留下的占位槽归它
    /// （计划书 §6 M5）。不清理：条目数以本会话跑过的 App 为上限。
    private var lastDisplay: [AppKey: CGDirectDisplayID] = [:]
    /// 每个窗口最后一次成为前台的序号。簇的封面取其中最大的那个成员。
    /// 与簇一样只在会话内有效——窗口本身就不跨重启。
    private(set) var lastActive: [CGWindowID: Int] = [:]
    private var activationClock = 0
    /// 窗口区的顺序。排布的单位是窗口，不是 App。
    let order = WindowOrder()
    let diagnostics = Diagnostics()

    private let store = WindowIndexStore()
    private let observers = AXObserverHub()
    private var iconCache: [pid_t: NSImage] = [:]
    private var fileIconCache: [URL: NSImage] = [:]

    let maximizer = Maximizer()
    let corrector = TilingCorrector()
    /// 拖格子分屏时画在桌面上的那块落点
    let splitPreview = SplitPreview()
    /// nil = 快捷键没注册上（组合被别的程序占用）。设置页据此说明情况。
    private(set) var fillHotKey: HotKey?

    private let tilePlugins = DockTilePlugins()
    private let badgeReader = BadgeReader()
    private let settings = SettingsWindowController()
    private var pendingApps = Set<pid_t>()
    private var coalesceScheduled = false
    private var suppressReadySync = false
    private let fullscreenWatch = FullscreenWatch()
    private let missionControl = MissionControlWatch()
    private let activityCenter = ActivityCenter()
    private var mouseMonitor: Any?

    // MARK: 每块屏的 bar
    //
    // 世界变了要通知每一条 bar 重排；反过来 bar 只读世界，不改它。
    // 持弱引用：bar 的生命周期由面板控制器管，显示器一拔就该整条消失。

    private struct WeakBar { weak var bar: BarModel? }
    private var registered: [WeakBar] = []
    var bars: [BarModel] { registered.compactMap(\.bar) }

    func register(_ bar: BarModel) {
        registered.append(WeakBar(bar: bar))
        bar.rebuildItems()
        refreshBarDisplays()
    }

    func unregister(_ bar: BarModel) {
        registered.removeAll { $0.bar === bar || $0.bar == nil }
        refreshBarDisplays()
    }

    /// 铺满与结果纠正要知道哪些屏上有常驻的 bar——只有它们才扣掉底部那一条。
    /// 自动隐藏的屏不算：那条 bar 平时不在，窗口该用满整块屏。
    func refreshBarDisplays() {
        let displays = Set(bars.filter { !$0.autoHides }.compactMap(\.display))
        maximizer.barDisplays = displays
        corrector.barDisplays = displays
    }

    // MARK: 每块屏的可见性（计划书 §6 M5）

    /// 这块屏的 bar 是自动隐藏还是始终显示。
    func autoHides(on display: CGDirectDisplayID?) -> Bool {
        guard let display, let uuid = displayUUID(display) else { return false }
        return pins.autoHiddenDisplays.contains(uuid)
    }

    func setAutoHides(_ value: Bool, on display: CGDirectDisplayID) {
        guard let uuid = displayUUID(display) else {
            // 存不下来就等于用户改完一重启又变回去，不能装作设上了
            report("无法为这块显示器保存可见性设置", "系统没有给出它的 UUID（显示器 \(display)）。")
            return
        }
        pins.setAutoHidden(value, display: uuid)
        bars.first { $0.display == display }?.setAutoHides(value)
        objectWillChange.send()
    }

    /// 世界的内容变了，每条 bar 都要重排一次自己的版面。
    func rebuild() {
        // 开出窗口即到达，弹跳该收了——但要等这一轮跳完，见 landBounce
        for id in windows.compactMap(\.bundleID) where launching.contains(id) { landBounce(id) }
        // 顺序与簇是全局的，先对齐一次，再让每条 bar 各挑自己那部分出格
        alignBarOrder(windows: windows, pins: pins, retained: retainedApps,
                      clusters: clusters, order: order)
        for bar in bars { bar.rebuildItems() }
    }

    // MARK: 显示器归属（计划书 §6 M5）

    /// 主显示器：菜单栏所在的那块，也就是坐标原点那块。不是 `NSScreen.main`——
    /// 那个跟的是键盘焦点，会随用户点哪块屏而变。
    var mainDisplay: CGDirectDisplayID? {
        NSScreen.screens.first.flatMap(displayID)
    }

    /// 这个窗口该出现在哪条 bar 上。
    ///
    /// 判不出归属的窗口落到主屏。这不是拿默认值盖住问题——`display` 保持 nil、
    /// 日志照记，但一个窗口无论如何不能哪条 bar 都不上：够不着比放错一块屏严重得多。
    func home(of window: IndexedWindow) -> CGDirectDisplayID? {
        window.display ?? mainDisplay
    }

    /// 一个此刻没有窗口的 App，它的占位槽归哪块屏。
    /// 固定 App 不走这条——它在每块屏上都有槽位。
    func home(of app: AppKey) -> CGDirectDisplayID? {
        lastDisplay[app] ?? mainDisplay
    }

    /// 把一个窗口搬到另一块屏（计划书 §6 M5「移到此显示器」）。
    ///
    /// 尺寸照旧，位置按它在原屏可见区域里的相对位置落下去，装不下就夹进目标的可见区域。
    /// 写位置用的是接管最大化那套 AX 双写——不擅自动 Space，也不碰窗口层级。
    func move(_ window: IndexedWindow, to display: CGDirectDisplayID) {
        guard let element = window.element else {
            Timeline.log("⚠️ 移到显示器跳过 wid \(window.id)：窗口在其他 Space，尚无 AX 引用")
            return
        }
        guard let target = NSScreen.screens.first(where: { displayID($0) == display }) else {
            Timeline.log("⚠️ 移到显示器跳过 wid \(window.id)：屏 \(display) 已经不在了")
            return
        }
        do {
            let area = target.visibleFrame
            let from = try screen(of: element).visibleFrame
            guard let rect = axRect(element) else { throw FillError.noGeometry }
            let frame = flipY(rect)
            let ratio = CGPoint(x: from.width > 0 ? (frame.minX - from.minX) / from.width : 0,
                                y: from.height > 0 ? (frame.minY - from.minY) / from.height : 0)
            let size = CGSize(width: min(frame.width, area.width),
                              height: min(frame.height, area.height))
            let origin = CGPoint(
                x: min(max(area.minX + ratio.x * area.width, area.minX), area.maxX - size.width),
                y: min(max(area.minY + ratio.y * area.height, area.minY), area.maxY - size.height))
            let outcome = try setFrame(element, to: flipY(CGRect(origin: origin, size: size)))
            if outcome.fits {
                Timeline.log("移到屏 \(display)  wid \(window.id) \(window.appName)")
            } else {
                // 没正确实现 AX 位置写入的 App 挪不动，这是该功能的已知失败模式
                Timeline.log("⚠️ 移到显示器未贴合 wid \(window.id) \(window.appName)："
                             + "实际 \(outcome.after.map(String.init(describing:)) ?? "读不回")")
            }
        } catch {
            Timeline.log("⚠️ 移到显示器失败 wid \(window.id) \(window.appName)：\(error)")
        }
    }

    // MARK: 在此显示器打开（计划书 §6 M5）

    /// 请 App 开一扇窗口之后，等那个窗口出现，再把它挪到指定的屏上。
    ///
    /// 认领要按 pid **或** bundle ID：从右键菜单开窗口时 App 一定在运行、pid 是现成的，
    /// 而点一个没运行的 App 时还没有 pid，只能靠 bundle ID 认。
    private struct PendingOpen {
        let pid: pid_t?
        let bundleID: String?
        let display: CGDirectDisplayID
        let deadline: Date

        func matches(_ window: IndexedWindow) -> Bool {
            if let pid { return window.pid == pid }
            if let bundleID { return window.bundleID == bundleID }
            return false
        }

        var label: String { pid.map { "pid \($0)" } ?? (bundleID ?? "?") }
    }
    private var pendingOpens: [PendingOpen] = []
    /// 等新窗口的上限。等不到就作罢并记一笔——不能悄悄丢掉一个用户发起过的动作。
    private static let openTimeout: TimeInterval = 10

    func openHere(pid: pid_t, app url: URL, item: DockMenu.Item, on display: CGDirectDisplayID) {
        expectWindow(pid: pid, bundleID: nil, on: display)
        DockMenu.press(app: url.path, at: item.path)
    }

    private func expectWindow(pid: pid_t?, bundleID: String?, on display: CGDirectDisplayID) {
        pendingOpens.append(PendingOpen(pid: pid, bundleID: bundleID, display: display,
                                        deadline: Date().addingTimeInterval(Self.openTimeout)))
    }

    /// - Parameter known: 这一轮之前就在索引里的窗口。新开出来的那个必然不在其中。
    private func resolvePendingOpens(fresh: [IndexedWindow], known: Set<CGWindowID>) {
        guard !pendingOpens.isEmpty else { return }
        let now = Date()
        pendingOpens = pendingOpens.filter { request in
            guard let window = fresh.first(where: {
                request.matches($0) && !known.contains($0.id)
            }) else {
                guard request.deadline > now else {
                    Timeline.log("⚠️ 「在此显示器打开」没等到新窗口：\(request.label)，已作罢")
                    return false
                }
                return true
            }
            if window.display != request.display { move(window, to: request.display) }
            return false
        }
    }

    // MARK: 启动

    func start() {
        updateMouseMonitor()
        observers.onEvent = { [weak self] pid, notification, element in
            guard let self else { return }
            Timeline.log("AX 事件  pid \(pid) \(Self.appName(pid))  \(notification)")
            // 窗口挪动 / 改大小不会改索引，走不到 publish 里那次采样，但条底下的颜色
            // 恰恰就是这么变的——单独接一下
            if notification == kAXWindowMovedNotification || notification == kAXWindowResizedNotification {
                sampleBackdrop()
            }
            if notification == kAXUIElementDestroyedNotification {
                if store.removeWindow(matching: element) {
                    Timeline.log("✕ 移出索引  [窗口销毁事件]")
                    publish()
                }
                return
            }
            enqueue(pid)
        }
        // 刚开始监听时补一次同步，追回订阅建立之前错过的窗口。
        // 但启动时的批量注册要跳过：已在运行的 App 第 0 次尝试即成功，会在 start() 里
        // 同步触发数十次回补，等于把冷启动全量 AX 扫描从后门放回来（计划书 §2 明令禁止）。
        // 重试成功的注册走 asyncAfter，天然落在抑制窗口之外——那才是真正需要回补的那批。
        observers.onReady = { [weak self] pid in
            guard let self else { return }
            diagnostics.watchedProcesses = observers.watchedProcessCount
            guard !suppressReadySync else { return }
            Timeline.log("订阅就绪  pid \(pid) \(Self.appName(pid))")
            enqueue(pid)
        }
        suppressReadySync = true
        observeAllRunningApps()
        suppressReadySync = false
        let center = NSWorkspace.shared.notificationCenter
        // 弹跳不区分是谁发起的启动：从聚焦搜索、访达、终端里打开的 App，
        // 只要它在条上有位置，也该弹。
        center.addObserver(forName: NSWorkspace.willLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let id = Self.app(from: note)?.bundleIdentifier else { return }
            self?.startBounce(id)
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let pid = Self.pid(from: note) else { return }
            Timeline.log("App 启动  pid \(pid) \(Self.appName(pid))")
            self?.observers.observe(pid: pid)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self, let pid = Self.pid(from: note) else { return }
            observers.stop(pid: pid)
            store.removeApp(pid: pid)
            activityCenter.remove(pid: pid)
            publish()
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self, let pid = Self.pid(from: note) else { return }
            // 重试阶梯共约 3.8s，冷启动更慢的 App（Electron 系）会永久留在失败集合里，
            // 从此听不到 kAXWindowCreated。用户激活它，正是最自然的重试时机。
            if observers.failedProcesses.contains(pid) { observers.observe(pid: pid) }
            refreshFrontWindow()
            enqueue(pid)
        }
        // 认领的关键时机。AX 只看得见当前 Space 的窗口，所以每次 Space 切换，
        // 都有一批此前够不着的窗口变得可见——抓住它们的 AX 引用，此后永久有效
        // （M0 已验证引用跨 Space 存活），它们才能进入低延迟通道。
        // 常驻程序的优势正在于此：用得越久覆盖越全，一次性探针做不到这件事。
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // 每块屏各有自己的活跃 Space，全屏判定因此逐条 bar 各算各的。
            fullscreenWatch.confirm()
            for bar in bars { bar.activeSpaceChanged() }
            claimVisibleWindows()
        }
        // 预判全屏动作，抢在系统的转场快照之前隐藏。这个 tap 看到的是手势本身，
        // 说不出它冲着哪块屏去——因此预判一来，每条 bar 都先藏，随后各自按本屏的
        // Space 类型校正回来（见 `BarModel.activeSpaceChanged`）。
        fullscreenWatch.onPredict = { [weak self] in
            guard let self else { return }
            for bar in bars { bar.predictFullscreen() }
        }
        fullscreenWatch.onTimeout = { [weak self] in
            guard let self else { return }
            for bar in bars { bar.fullscreenPredictionTimedOut() }
        }
        fullscreenWatch.start()
        missionControl.onChange = { [weak self] active in
            guard let self else { return }
            for bar in bars { bar.setYielding(active) }
        }
        missionControl.start()
        activityCenter.onChange = { [weak self] in
            guard let self else { return }
            activities = activityCenter.activities
        }
        activityCenter.start()
        corrector.enabled = pins.correctsTiling
        observers.watchesGeometry = pins.correctsTiling
        observers.onGeometryChanged = { [weak self] element in
            self?.corrector.handle(element)
        }
        fillHotKey = HotKey(keyCode: HotKey.fillKeyCode, modifiers: HotKey.fillModifiers) {
            [weak self] in self?.maximizer.toggleFrontWindow()
        }
        if fillHotKey == nil {
            Timeline.log("⚠️ 铺满快捷键 ⌃⌥⌘F 注册失败，该组合已被其他程序占用")
        }
        for bar in bars { bar.refreshFullscreenState() }
        refreshFrontWindow()
        refreshTrash()
        rebuild()
    }

    /// 计划书 §4：对每个运行中 App 订阅，而不只是「索引里已有窗口」的那几个——
    /// 否则一个当前没有窗口的 App 新开窗口时，kAXWindowCreated 没人在听。
    private func observeAllRunningApps() {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy != .prohibited && app.processIdentifier != getpid() {
            observers.observe(pid: app.processIdentifier)
        }
        diagnostics.watchedProcesses = observers.watchedProcessCount
    }

    /// Space 切换后认领新可见的窗口。留一点延迟等系统把 AX 树切过去。
    private func claimVisibleWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let unclaimed = Set(store.windows.filter { $0.element == nil }.map(\.pid))
            var changed = false
            for pid in unclaimed where store.refreshApp(pid: pid) { changed = true }
            if changed { publish() }
            subscribeToKnownWindows()
        }
    }

    private static func app(from note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private static func pid(from note: Notification) -> pid_t? {
        app(from: note)?.processIdentifier
    }

    // MARK: 通道三

    func reconcile() {
        // 跟着对账 tick 采一次背景亮度。这里必须是周期性的，不能只挂在事件上：
        // 条底下那个窗口自己换了内容（切页、播视频、换主题）不触发我们的任何事件，
        // 而那正是最常见的情况。单次约 35ms，异步，只在条可见时进行。
        sampleBackdrop()
        guard accessibility else { return }
        let before = Set(store.windows.map(\.id))
        let changed = store.reconcile()
        diagnostics.timing = store.timing
        for window in store.windows where !before.contains(window.id) {
            Timeline.log("★ 进入索引  wid \(window.id) \(window.appName) — \(window.title)  [对账兜底]")
        }
        if changed { publish() }
        subscribeToKnownWindows()
    }

    /// 只对已拿到 AX 引用的窗口注册窗口级通知；跨 Space 的存量窗口没有引用，
    /// 只能等它被认领后再订阅——期间由通道三兜底。
    private func subscribeToKnownWindows() {
        for window in store.windows {
            guard let element = window.element else { continue }
            observers.watch(window: element, pid: window.pid)
            corrector.note(wid: window.id, element: element)
        }
        diagnostics.watchedProcesses = observers.watchedProcessCount
        diagnostics.unclaimedWindows = store.windows.count { $0.element == nil }
        diagnostics.unobservedProcesses = observers.failedProcesses.count
    }

    // MARK: 通道二（合并同一帧内的重复事件）
    //
    // 终端里连续输出会让标题变更事件密集触发，逐个响应等于把省下来的开销又烧回去。

    private func enqueue(_ pid: pid_t) {
        pendingApps.insert(pid)
        diagnostics.events += 1
        guard !coalesceScheduled else { return }
        coalesceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            coalesceScheduled = false
            let apps = pendingApps
            pendingApps.removeAll()
            var changed = false
            for pid in apps {
                let before = Set(store.windows.map(\.id))
                if store.refreshApp(pid: pid) { changed = true }
                let added = store.windows.filter { !before.contains($0.id) }
                for window in added {
                    Timeline.log("★ 进入索引  wid \(window.id) \(window.appName) — \(window.title)  [定向刷新]")
                }
                for skipped in store.lastSkipped {
                    Timeline.log("  定向刷新跳过  \(skipped)")
                }
            }
            refreshFrontWindow()
            if changed { publish() }
            subscribeToKnownWindows()
        }
    }

    private static func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    }

    private func publish() {
        noteDisplayChanges(to: store.windows)
        resolvePendingOpens(fresh: store.windows, known: Set(windows.map(\.id)))
        windows = store.windows
        // 窗口全关之后占位槽要留在原处，所以归属得趁窗口还在的时候记下来
        for window in windows {
            guard let display = window.display else { continue }
            lastDisplay[window.appKey] = display
        }
        rebuild()
        sampleBackdrop()
    }

    /// 这一轮刚换了显示器的窗口 → 它原来在哪块屏。收到它的那条 bar 据此让格子
    /// 从那个方向飞进来——「我那一格去哪了」在多屏下同样必须看得见。
    private(set) var justMigrated: [CGWindowID: CGDirectDisplayID] = [:]

    /// 显示器归属的变化（计划书 §6 M5）。
    private func noteDisplayChanges(to fresh: [IndexedWindow]) {
        // 值本身是可选的，所以查表得到的是双层可选：外层 nil 表示上一轮没有这个窗口。
        var before: [CGWindowID: CGDirectDisplayID?] = [:]
        for window in windows { before[window.id] = window.display }
        var migrated: [CGWindowID: CGDirectDisplayID] = [:]
        for window in fresh {
            guard let previous = before[window.id] else {
                if window.display == nil {
                    Timeline.log("⚠️ 新窗口判不出显示器  wid \(window.id) \(window.appName)")
                }
                continue
            }
            guard previous != window.display else { continue }
            Timeline.log("跨屏  wid \(window.id) \(window.appName)"
                + "  \(Self.displayName(previous)) → \(Self.displayName(window.display))")
            // 判不出归属的窗口落在主屏上（见 home(of:)），来向也就是主屏
            migrated[window.id] = previous ?? mainDisplay
        }
        justMigrated = migrated
    }

    private static func displayName(_ display: CGDirectDisplayID?) -> String {
        display.map { "屏 \($0)" } ?? "未知"
    }

    private func sampleBackdrop() {
        for bar in bars { bar.sampleBackdrop() }
    }

    // MARK: 前台窗口
    //
    // 走「前台 App 的 AX 元素 -> kAXFocusedWindow」。不走系统级 kAXFocusedApplication：
    // M0 实测它对 Electron/Chromium 系（VS Code、Arc）返回 nil。

    private func refreshFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { frontWindow = nil; return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let focused = axCopy(axApp, kAXFocusedWindowAttribute) else { frontWindow = nil; return }
        let id = windowID(of: focused as! AXUIElement).id
        // 先比再赋值：赋值之后 frontWindow 就等于 id 了，比不出「变没变」
        if let id, frontWindow != id {
            activationClock += 1
            lastActive[id] = activationClock
        }
        let changed = frontWindow != id
        frontWindow = id
        // 前台窗口一换，条底下多半就是另一块颜色了
        if changed { sampleBackdrop() }
    }

    // MARK: 指针
    //
    // 只有一处监听，转发给每条 bar；哪条 bar 该理会由它自己按屏判断。
    // 全屏下的触底唤出是唯一的用户，非全屏时一次监听都不必挂。

    func updateMouseMonitor() {
        let needed = bars.contains { $0.wantsPointer }
        if needed {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                guard let self else { return }
                let point = NSEvent.mouseLocation
                for bar in bars { bar.pointerMoved(to: point) }
            }
        } else {
            mouseMonitor.map(NSEvent.removeMonitor)
            mouseMonitor = nil
            for bar in bars { bar.cancelPointerDwell() }
        }
    }

    /// 清倒废纸篓。
    ///
    /// 没有公开 API，只能请访达代劳，因此会触发一次「自动化」权限询问——
    /// 这是用户主动点了才发生的按需权限，不进 §4 的必需权限模型。
    /// 不可逆，先确认。
    func emptyTrash() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "确定要清倒废纸篓吗？"
        alert.informativeText = "废纸篓中的项目将被永久删除。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清倒")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?
            .executeAndReturnError(&error)
        if let error {
            report("无法清倒废纸篓", "\(error["NSAppleScriptErrorMessage"] ?? error)")
            return
        }
        refreshTrash()
    }

    // MARK: 系统程序坞

    var systemDockSuppressed: Bool { DockControl.isSuppressed }

    func suppressSystemDock() {
        pins.setDockSnapshot(DockControl.suppress())
        objectWillChange.send()
    }

    func restoreSystemDock() {
        DockControl.restore(pins.dockSnapshot)
        pins.setDockSnapshot(nil)
        objectWillChange.send()
    }

    // MARK: 系统 Dock 引导
    //
    // 计划书 §4 已知硬约束：屏幕空间保留无公开 API（系统 Dock 独占），
    // 方案是引导用户把系统 Dock 设为自动隐藏，本体浮于底部。
    // 只读状态、只给入口——不代用户写 com.apple.dock。

    var systemDockAutoHidden: Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    func openDockSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.dock") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 图标

    func icon(pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        iconCache[pid] = icon
        return icon
    }

    /// App 的本地化名称。用包文件名会显示成「Finder」「System Settings」，
    /// 而系统各处显示的是「访达」「系统设置」。
    func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    /// 文件夹、垃圾桶一类的文件图标
    func icon(file url: URL) -> NSImage? {
        if let cached = fileIconCache[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        fileIconCache[url] = icon
        return icon
    }

    /// App 图标。先问它自己的 dock tile 插件——用户在 App 内换过的图标只存在于那里，
    /// 从 bundle 读永远是默认图标（见 DockTilePlugins 的说明）。
    func icon(app url: URL?, bundleID: String?) -> NSImage? {
        guard let url else { return nil }
        if let cached = fileIconCache[url] { return cached }
        let icon = bundleID.flatMap { tilePlugins.icon(app: url, bundleID: $0) }
            ?? NSWorkspace.shared.icon(forFile: url.path)
        fileIconCache[url] = icon
        return icon
    }

    func icon(for cell: BarWindow) -> NSImage? {
        icon(app: NSRunningApplication(processIdentifier: cell.pid)?.bundleURL,
             bundleID: cell.bundleID)
    }

    /// 条上还没拿到权限时顶替内容的提示。
    var notice: String? {
        if !accessibility { return "需要「辅助功能」权限" }
        if !screenRecording { return "需要「屏幕录制」权限" }
        return nil
    }

    /// 留位判据就是系统程序坞自己的判据：运行中的 regular App。LSUIElement（accessory）
    /// 的 App 不在其列，所以 Stats、Clash Verge 这些窗口全关之后不留位——但它们的真窗口
    /// 照常进条（§4），变的只是关完之后不替它们守位置。
    ///
    /// 这里刻意不累积「本会话开过窗口」。那样的集合只能靠亲眼看见窗口来增长，Dockline
    /// 一重启就清零，微信、QQ 这类关掉窗口但进程还在的 App 要等用户用别的方式再开一次
    /// 窗口才回得来。留位状态必须当场从世界推导，不能攒——攒出来的东西都过不了重启。
    var retainedApps: Set<AppKey> {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier.map(AppKey.bundle) }
        // 正在启动的 App 也占一个位置，哪怕它既没被固定、这个会话里也还没开过窗口——
        // 否则「启动中」这个状态无处可画，弹跳等于不存在。系统程序坞也是这么做的：
        // 启动的一瞬间就插一格进去，窗口出来之后原地变成它的窗口格（id 不变，见 BarItem.id）。
        return Set(running).union(launching.map(AppKey.bundle))
    }

    // MARK: 固定与非窗口区（计划书 §3 / M3）

    func togglePin(_ bundleID: String) {
        pins.isPinned(bundleID) ? pins.unpin(bundleID) : pins.pin(bundleID)
        rebuild()
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "固定"
        // 面板是 nonactivating 的，不先激活自己，NSOpenPanel 会开在后面看不见
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { pins.addFolder(url) }
        rebuild()
    }

    func removeFolder(_ url: URL) {
        pins.removeFolder(url)
        rebuild()
    }

    /// 点击格子：召回。后台标签页没有 AX 元素，改按标签栏上的那一项。
    /// 我们自己把某个窗口切到了前台。
    ///
    /// 前台窗口平时靠 `kAXFocusedWindowChangedNotification` 更新，那条路要经 80ms 合并、
    /// 再加 AX 自身的延迟。键盘切换连按两次的间隔比这短，等通知回来再排序，第二次读到的
    /// 还是上一轮的名次，于是「上一个窗口」算成刚切过去的那个，来回切换变成原地不动。
    /// 这里不是兜底：谁在前台是我们刚刚亲自决定的，直接记下来即可。
    func noteActivated(_ id: CGWindowID) {
        activationClock += 1
        lastActive[id] = activationClock
        frontWindow = id
    }

    /// 时间序：最近用过的排在前面，第一个就是当前前台窗口。键盘切换的 Tab 走这条。
    ///
    /// `clock` 是外部冻结的一份活跃序号，键盘切换用它在一次会话里固定名次。冻的是名次，
    /// 不是名单：名单必须跟着索引走。新窗口进索引要等 AX 通知，用户往往在那之前就按下了
    /// ⌥Tab，名单一冻，那个窗口整场会话都够不着。它不在 `clock` 里，于是用实时序号——
    /// 刚建出来的窗口正被聚焦，序号最大，排在最前，本来就该如此。
    ///
    /// 从未聚焦过的窗口序号都是 0。并列时按条上的排布定序：`sorted` 不保证稳定，
    /// 不给第二关键字的话这批窗口每次算出来的次序都可能不同，⌥Tab 会走得像随机的。
    func recencyOrder(clock: [CGWindowID: Int] = [:]) -> [IndexedWindow] {
        var place: [CGWindowID: Int] = [:]
        for (index, window) in spatialOrder.enumerated() { place[window.id] = index }
        func rank(_ window: IndexedWindow) -> Int { clock[window.id] ?? lastActive[window.id] ?? 0 }
        return windows.sorted {
            let left = rank($0), right = rank($1)
            guard left == right else { return left > right }
            return (place[$0.id] ?? .max) < (place[$1.id] ?? .max)
        }
    }

    /// 空间序：各条 bar 按屏幕从左到右接起来，条内按格子的排布顺序。方向键走这条。
    /// 单屏时它就退化成「条上从左到右」。
    var spatialOrder: [IndexedWindow] {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = bars.sorted { left, right in
            (left.screenOriginX ?? 0) < (right.screenOriginX ?? 0)
        }
        return ordered.flatMap { $0.windowSequence }.compactMap { byID[$0] }
    }

    func recall(_ window: IndexedWindow) {
        guard case .tab(let host) = window.source else {
            DocklineCore.recall(window)
            return
        }
        do {
            try recallTab(window, host: host)
        } catch {
            Timeline.log("⚠️ 切换标签页失败 wid \(window.id) \(window.appName)：\(error)")
        }
    }

    /// 贴到落点（计划书 §3「接管最大化」）。
    ///
    /// 两个入口的语义差一处：右键菜单里那一排图形**已经贴合就还原**（同一个记号一来一回），
    /// 拖格子分屏则一律照贴——把格子丢到左半边，意思就是左半边。
    ///
    /// 两者都先召回再摆位。反过来的话，最小化的窗口是摆不动的——它得先从最小化里出来，
    /// 而那一步正是召回做的。代价是普通窗口会在旧位置上露一两帧，比摆不动轻。
    /// 前置本身也是要的：用户刚把它放到这儿，要的就是它；它若压在别人底下，
    /// 不前置的话屏幕上什么都不会发生。
    func snap(_ window: IndexedWindow, to spot: Maximizer.Spot) {
        // 菜单没有「指针指着哪块屏」这回事，迁的话就迁到它自己那块屏当前的 Space。
        reach(window, on: window.display, why: "平铺") { [weak self] element in
            guard let self, let element else { return }
            recall(window)
            noteActivated(window.id)
            maximizer.toggle(window, at: spot, using: element)
        }
    }

    /// **目标屏由手势给**——指针指着哪块屏，就贴那块屏的那一半；窗口此刻在哪块屏与此无关。
    func tile(_ window: IndexedWindow, at spot: Maximizer.Spot, on display: NSScreen) {
        reach(window, on: displayID(display), why: "分屏") { [weak self] element in
            guard let self else { return }
            defer { splitPreview.dissolve() }
            guard let element else { return }
            recall(window)
            noteActivated(window.id)
            maximizer.place(window, at: spot, on: display, using: element)
        }
    }

    /// 把窗口变成「摆得动的」，再把 AX 引用交出去。
    ///
    /// 当前 Space 上的窗口本来就有引用，同步交出；别的 Space 上的没有——摆位要写它的
    /// 几何，写几何要引用，所以先把它迁到 `display` 当前的 Space（计划书 §5 第 1.5 层，
    /// §2 的写操作例外），迁完再交。迁不了就交 nil，并在这里把原因说清楚：调用点只负责
    /// 收场，不各自再编一遍话术。
    private func reach(_ window: IndexedWindow, on display: CGDirectDisplayID?,
                       why: String, then body: @escaping (AXUIElement?) -> Void) {
        if let element = window.element {
            body(element)
            return
        }
        guard SpaceMove.available else {
            Timeline.log("⚠️ \(why)放弃 wid \(window.id) \(window.appName)：窗口在其他 Space，"
                         + "而迁移能力不可用（缺 \(SpaceMove.missing.joined(separator: ", "))）")
            body(nil)
            return
        }
        guard let display, let space = SpaceMove.currentSpace(on: display),
              SpaceMove.isDesktop(space) else {
            Timeline.log("⚠️ \(why)放弃 wid \(window.id) \(window.appName)：目标屏当前的 Space"
                         + "取不到，或者它不是普通桌面")
            body(nil)
            return
        }
        guard SpaceMove.move(window.id, to: space) else {
            Timeline.log("⚠️ \(why)放弃 wid \(window.id) \(window.appName)：迁到 Space \(space) 没调成")
            body(nil)
            return
        }
        // 迁移是异步的、不给错误码：归属与 AX 引用都要等实际信号（实测各十几到几十毫秒）。
        // 分屏的落点预览这段时间一直挂着，正好把它盖住。
        awaitMigration(window, to: space) { element in
            if element == nil {
                Timeline.log("⚠️ \(why)放弃 wid \(window.id) \(window.appName)：迁过来了，"
                             + "但等不到它的 AX 引用")
            }
            body(element)
        }
    }

    /// 等归属变过来、再等 AX 引用出现。都拿不到就交出 nil，由调用点放弃并说明。
    ///
    /// 轮询而不是订阅：窗口服务器没有为这件事广播任何东西，而这是用户一次显式动作里的
    /// 一小段，不是常驻路径（计划书 §2 的预算管的是稳态 tick）。
    private func awaitMigration(_ window: IndexedWindow, to space: UInt64,
                                then body: @escaping (AXUIElement?) -> Void) {
        let deadline = Date().addingTimeInterval(1)
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func poll() {
            guard Date() < deadline else {
                body(nil)
                return
            }
            if SkyLight.spaces(for: window.id)?.contains(space) == true,
               let element = (axCopy(app, kAXWindowsAttribute) as? [AXUIElement] ?? [])
                .first(where: { windowID(of: $0).id == window.id }) {
                body(element)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
        }
        poll()
    }

    /// 这个窗口此刻贴在哪个落点上。菜单里那一排图形据此显示选中态。
    func spot(of window: IndexedWindow) -> Maximizer.Spot? {
        maximizer.spot(of: window)
    }

    var correctsTiling: Bool { pins.correctsTiling }

    var foldsTabs: Bool { pins.foldsTabs }

    func setFoldsTabs(_ enabled: Bool) {
        pins.setFoldsTabs(enabled)
        publish()
    }

    func setCorrectsTiling(_ enabled: Bool) {
        pins.setCorrectsTiling(enabled)
        corrector.enabled = enabled
        observers.watchesGeometry = enabled
        objectWillChange.send()
    }

    /// 右键退出 App。用 terminate（发 quit 事件），不用 forceTerminate——
    /// 有未保存内容的 App 需要机会弹出它自己的确认框。
    func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// 关掉一个窗口。按的是窗口自己的关闭按钮，和用户点红灯完全同一条路径——
    /// 有未保存内容的 App 照常弹它自己的确认框。
    func close(_ window: IndexedWindow) {
        guard let element = window.element else {
            Timeline.log("⚠️ 关闭跳过 wid \(window.id)：窗口在其他 Space，尚无 AX 引用")
            return
        }
        guard let button = axCopy(element, kAXCloseButtonAttribute) else {
            Timeline.log("⚠️ 关闭跳过 wid \(window.id) \(window.appName)：这个窗口没有关闭按钮")
            return
        }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    func isHidden(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
    }

    func toggleHidden(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        _ = app.isHidden ? app.unhide() : app.hide()
    }

    /// 把这个 App 的全部窗口一起调到前台。系统程序坞的「显示全部窗口」在我们这儿
    /// 没有意义——条上本来就全在，缺的是「一次全叫上来」。
    func raiseAll(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    func windowCount(pid: pid_t) -> Int {
        windows.count { $0.pid == pid }
    }

    func appURL(pid: pid_t) -> URL? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 拖动结束或滑块松手时落盘。拖动过程中只改内存，不必每一帧写文件。
    func commitIconSize() {
        pins.setIconSize(iconSize)
    }

    func resetIconSize() {
        pins.setIconSize(nil)
        iconSize = BarMetrics.systemDockTileSize
    }

    // MARK: 登录时启动

    var launchesAtLogin: Bool { LoginItem.isEnabled }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            report("无法更改登录时启动", LoginItem.requiresApproval
                   ? "请在「系统设置 › 通用 › 登录项与扩展」中允许 Dockline。"
                   : error.localizedDescription)
        }
        objectWillChange.send()
    }

    func showSettings() {
        settings.show(model: self)
    }

    func setLauncher(_ url: URL) {
        pins.setLauncher(url)
        rebuild()
    }

    func chooseLauncher() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "设为启动台入口"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLauncher(url)
    }

    // MARK: 捏合成簇（计划书 §3 / M4）

    /// 拖一个窗口格压到另一个上：二者吸合成簇。成员是窗口，不是 App——
    /// 同一个 App 的另外几个窗口不该被顺带拖进来。
    func formCluster(_ unit: DragUnit, into target: DragUnit) {
        let moving = elements(of: unit)
        let windows = moving.compactMap { element -> CGWindowID? in
            guard case .window(let id) = element else { return nil }
            return id
        }
        guard !windows.isEmpty else { return }

        switch target {
        case .window(let anchor):
            _ = clusters.merge(windows, intoWindow: anchor)
            // 簇要落在目标原本的位置上，所以成员集中到目标的紧后面
            for element in moving { order.place(element, after: .window(anchor)) }
        case .cluster(let id):
            clusters.merge(windows, intoCluster: id)
            if let anchor = clusters.members(of: id).first(where: { !windows.contains($0) }) {
                for element in moving { order.place(element, after: .window(anchor)) }
            }
        case .app:
            return   // 没有窗口的 App 不参与——它对「整组前置」没有贡献
        }
        rebuild()
    }

    /// 从簇里移出一个窗口。移出后只剩一个成员的簇会自动解散。
    func detachFromCluster(_ window: CGWindowID) {
        clusters.detach(window)
        rebuild()
    }

    /// 把窗口收进一个已有的编组。菜单里给不出「新建编组」——只剩一个成员的簇会自己
    /// 解散，从一个窗口起头建不出簇来，那条路只有捏合。
    func addToCluster(_ window: CGWindowID, _ id: Int) {
        clusters.merge([window], intoCluster: id)
        rebuild()
    }

    /// 簇的整体开关（计划书 §3）。与单个窗口是同一条规则：不在眼前就带到眼前，
    /// 已在眼前就收起来。判据取「前台窗口是不是这个簇的成员」。
    ///
    /// 这是簇唯一独有的能力——系统程序坞与 Mission Control 都做不到「把一组窗口一起调上来」。
    func toggleCluster(_ id: Int) {
        let members = clusters.members(of: id)
        let cells = windows.filter { members.contains($0.id) }
        guard let front = frontWindow, members.contains(front) else {
            for window in cells { recall(window) }
            return
        }
        // 后台标签页没有 AX 元素，最小化不了。整体收起时跳过它们并记一笔，
        // 不能装作整组都收起来了。
        let skipped = cells.filter { $0.element == nil }
        for window in cells where window.element != nil { minimizeWindow(window) }
        if !skipped.isEmpty {
            Timeline.log("整体最小化跳过 \(skipped.count) 个没有 AX 元素的成员（后台标签页）")
        }
    }

    func renameCluster(_ id: Int) {
        guard let cluster = clusters.cluster(id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "为这个编组命名"
        alert.informativeText = "留空则显示其中最近使用的窗口标题。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = cluster.name ?? ""
        field.placeholderString = "编组名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clusters.rename(id, to: field.stringValue.trimmingCharacters(in: .whitespaces))
        rebuild()
    }

    func recolorCluster(_ id: Int, to color: ClusterColor) {
        clusters.recolor(id, to: color)
        rebuild()
    }

    func toggleClusterName(_ id: Int) {
        clusters.toggleName(id)
        publish()
    }

    func dissolveCluster(_ id: Int) {
        clusters.dissolve(id)
        rebuild()
    }

    // MARK: 顺序

    /// 一个可拖动单位对应顺序里的哪些元素
    func elements(of unit: DragUnit) -> [BarElement] {
        switch unit {
        case .window(let id): return [.window(id)]
        case .app(let key): return [.app(key)]
        case .cluster(let id): return clusters.members(of: id).map(BarElement.window)
        }
    }

    func move(_ unit: DragUnit, before target: DragUnit?) {
        let destination = target.flatMap { elements(of: $0).first }
        for element in elements(of: unit).reversed() {
            order.move(element, before: destination)
        }
        rebuild()
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 固定槽位上没有窗口的 App。
    ///
    /// 一律走 openApplication，不为「已在运行」单开一条 activate 分支：
    /// activate 只是把 App 提到前台、不发 reopen 事件，而这个槽位上的 App 恰恰是
    /// 一个窗口都没有的——像系统设置那样关掉窗口后进程还在的，activate 一下什么也不会发生。
    /// openApplication 对运行中的 App 同样发 reopen，这正是 Dock 点击的语义。
    /// - Parameter display: 从哪块屏的条上点的。它开出来的窗口要落在这块屏上——
    ///   用户在哪儿点就在哪儿出现（计划书 §6 M5「对象全局，交互就地」）。
    ///
    ///   macOS 没有「在这块屏打开」的接口，落点由 App 自己的窗口恢复决定，通常是它上一次
    ///   出现的那块屏。只能事后搬：等它的第一扇窗口出现，不在这块屏就挪过来。代价是窗口
    ///   会先在别处冒出来再飞过来——想彻底避免只有「先藏起来摆好再显示」一条路，那要动
    ///   别人的窗口，不做。
    func launch(_ app: DormantApp, on display: CGDirectDisplayID?) {
        guard let url = app.url else {
            report("无法打开此 App", "它可能已被移除或重新命名。")
            return
        }
        if let display {
            expectWindow(pid: app.pid, bundleID: app.bundleID, on: display)
        }
        startBounce(app.bundleID)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 弹跳的正常终止条件是「这个 App 有窗口了」（见 `BarModel.rebuildItems`）。但 App 可能
    /// 启动失败，也可能压根不开窗口——动画必须有个兜底的终止条件。
    private static let bounceTimeout: TimeInterval = 10

    private func startBounce(_ bundleID: String) {
        guard !launching.contains(bundleID) else { return }
        bounceStarted[bundleID] = Date()
        // 条上要先有这一格才弹得起来，所以插完集合必须立刻重排
        launching.insert(bundleID)
        rebuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bounceTimeout) { [weak self] in
            self?.landBounce(bundleID)
        }
    }

    /// 让当前这一轮跳完再落地。中途撤掉 `bouncing`，关键帧会就地停住，图标卡在半空。
    func landBounce(_ bundleID: String) {
        guard let started = bounceStarted[bundleID], landing.insert(bundleID).inserted else { return }
        let elapsed = Date().timeIntervalSince(started)
        let rest = LaunchBounce.cycle - elapsed.truncatingRemainder(dividingBy: LaunchBounce.cycle)
        DispatchQueue.main.asyncAfter(deadline: .now() + rest) { [weak self] in
            guard let self else { return }
            landing.remove(bundleID)
            bounceStarted[bundleID] = nil
            guard launching.remove(bundleID) != nil else { return }
            rebuild()
        }
    }

    // MARK: 文件操作
    //
    // 计划书 §3：固定文件夹是「拖拽目标 + 快速入口」。移动而非复制——它是动线的终点。

    func move(_ urls: [URL], into folder: URL) {
        for url in urls {
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                report("无法将「\(url.lastPathComponent)」移到「\(folder.lastPathComponent)」", error.localizedDescription)
                return
            }
        }
    }

    func moveToTrash(_ urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                report("无法将「\(url.lastPathComponent)」移到废纸篓", error.localizedDescription)
                return
            }
        }
        refreshTrash()
    }

    /// 文件操作失败必须让用户当场看见——静默失败会让人以为文件已经移过去了。
    private func report(_ message: String, _ detail: String) {
        Timeline.log("⚠️ \(message)：\(detail)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 废纸篓
    //
    // 空 / 满状态不读 ~/.Trash——那个目录自 10.15 起要「完全磁盘访问权限」，
    // 而本权限模型只含辅助功能 + 屏幕录制。系统 Dock 自己把状态写在
    // com.apple.dock 的 trash-full 键里，读那个不需要任何额外权限。

    @Published private(set) var trashFull = false

    var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0]
    }

    /// 必须走 CFPreferences 并显式同步：Dock 把这个值更新在 cfprefsd 里、不一定刷盘，
    /// UserDefaults(suiteName:) 读到的是自己缓存过的磁盘快照，删完文件也不会变。
    /// 只查条上显示着的那几个 App。
    func refreshBadges() {
        var apps: [String: URL] = [:]
        func note(_ cell: BarWindow) {
            guard let id = cell.bundleID,
                  let url = NSRunningApplication(processIdentifier: cell.pid)?.bundleURL
            else { return }
            apps[id] = url
        }
        for item in bars.flatMap(\.barItems) {
            switch item {
            case .window(let cell):
                note(cell)
            case .cluster(let cluster):
                cluster.windows.forEach(note)
            case .dormant(let app):
                guard let url = app.url else { continue }
                apps[app.bundleID] = url
            default:
                continue
            }
        }
        let fresh = badgeReader.badges(for: apps, plugins: tilePlugins)
        if fresh != badges { badges = fresh }
    }

    func refreshTrash() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let value = CFPreferencesCopyAppValue("trash-full" as CFString,
                                              "com.apple.dock" as CFString) as? NSNumber
        trashFull = value?.boolValue ?? false
    }
}
