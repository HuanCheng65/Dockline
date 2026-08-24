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

/// 三通道汇流点。
///  · 通道一 NSWorkspace：App 启动 / 退出 / 激活
///  · 通道二 AXObserver：窗口创建 / 销毁 / 标题变更 / 最小化 / 取消最小化（低延迟主通道）
///  · 通道三 CG 对账：定期兜底存在性——AX 通知在 Electron 系 App 上确有漏报
final class BarModel: ObservableObject {
    @Published private(set) var windows: [IndexedWindow] = []
    @Published var accessibility = false { didSet { rebuildItems() } }
    @Published var screenRecording = false { didSet { rebuildItems() } }
    /// bar 上的顶层项。在数据变化时算一次，不在视图 body 里算——
    /// makeBarItems 会更新顺序记忆并落盘，那不该是渲染的副作用。
    @Published private(set) var barItems: [BarItem] = []
    /// 当前前台窗口——底色「亮底」档的唯一依据
    @Published private(set) var frontWindow: CGWindowID?
    /// 条背后的背景是偏亮还是偏暗。手绘层与文字据此取色——玻璃自己不管这件事
    /// （只对 ≤64pt 的玻璃管，见 `DockGlass`），所以由 `BackdropSensor` 自己采。
    @Published private(set) var backdropScheme: ColorScheme = .light
    /// 浮层（簇面板、预览卡）背后的明暗。它们浮在条的上方，底下压的常常不是
    /// 同一块东西，所以单独采一次。
    @Published private(set) var floatScheme: ColorScheme = .light
    /// 全屏场景自动隐藏（计划书 §4）。触底唤出时置回 false。
    @Published private(set) var hidden = false
    /// 条正在换屏：先滑下去，挪好了再滑上来。
    @Published private(set) var sliding = false
    /// 正在启动的 App。系统 Dock 用图标弹跳表示「点到了，正在开」——
    /// 开一个 App 到窗口出现有好几秒，没有反馈时用户会以为没点上。
    @Published private(set) var launching: Set<String> = []
    /// 每个正在弹跳的 App 的起跳时刻与「已排好落地」标记，供 `landBounce` 对齐轮次
    private var bounceStarted: [String: Date] = [:]
    private var landing: Set<String> = []
    /// 屏幕可见宽度，宽度降级阶梯的分母
    var availableWidth: CGFloat = 1440
    /// 图标尺寸。缺省跟随系统程序坞，用户可拖分隔线或在设置中调整。
    @Published var iconSize: CGFloat = BarMetrics.iconFull {
        didSet { BarMetrics.iconFull = iconSize }
    }

    let pins = PinStore()
    let clusters = ClusterStore()
    private let labelWidths = LabelWidths()
    private let backdrop = BackdropSensor(name: "条")
    private let floatBackdrop = BackdropSensor(name: "浮层")
    /// 玻璃条在根坐标系里的位置，由视图报上来
    private var barFrame: CGRect = .zero
    /// 当前浮层在根坐标系里的位置。nil = 没有浮层。
    private var floatFrame: CGRect?
    /// 根坐标系 → 所在屏幕左上原点坐标 的平移量，由 `BarPanel` 报上来
    private var rootOffset: CGPoint = .zero
    /// 每个窗口最后一次成为前台的序号。簇的封面取其中最大的那个成员。
    /// 与簇一样只在会话内有效——窗口本身就不跨重启。
    private var lastActive: [CGWindowID: Int] = [:]
    private var activationClock = 0
    /// 窗口区的顺序。排布的单位是窗口，不是 App。
    let order = WindowOrder()
    let diagnostics = Diagnostics()

    private let store = WindowIndexStore()
    private let observers = AXObserverHub()
    private var iconCache: [pid_t: NSImage] = [:]
    private var fileIconCache: [URL: NSImage] = [:]
    /// 未读角标，按 bundle ID。只在真的变了才发布，否则每 2 秒一次的读取会
    /// 把整条 bar 重绘一遍，打断动画。
    @Published private(set) var badges: [String: String] = [:]

    let maximizer = Maximizer()
    let corrector = TilingCorrector()
    /// nil = 快捷键没注册上（组合被别的程序占用）。设置页据此说明情况。
    private(set) var fillHotKey: HotKey?

    private let tilePlugins = DockTilePlugins()
    private let badgeReader = BadgeReader()
    private let settings = SettingsWindowController()
    /// 本会话开过窗口的 App。用于「窗口全关了但进程还在」时保住槽位。
    private var everHadWindows = Set<AppKey>()
    private var pendingApps = Set<pid_t>()
    private var coalesceScheduled = false
    private var suppressReadySync = false
    private let fullscreenWatch = FullscreenWatch()
    /// 活动状态，按上报进程。计划书 §3。
    @Published private(set) var activities: [pid_t: Activity] = [:]
    private let activityCenter = ActivityCenter()
    /// 该把条搬到哪块屏。面板的几何归 BarPanel 管，这里只发信号。
    var onFollowScreen: ((NSScreen) -> Void)?
    private var mouseMonitor: Any?
    private var dwell: DispatchWorkItem?
    private var moveDwell: DispatchWorkItem?
    private var inFullscreenSpace = false

    // MARK: 启动

    func start() {
        updateMouseMonitor()
        // 明暗翻转要过渡，不能一帧切过去——整条 bar 的文字同时换色，硬切很扎眼
        backdrop.onChange = { [weak self] scheme in
            withAnimation(.easeInOut(duration: 0.15)) { self?.backdropScheme = scheme }
        }
        floatBackdrop.onChange = { [weak self] scheme in
            withAnimation(.easeInOut(duration: 0.15)) { self?.floatScheme = scheme }
        }
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
            if let id = bundleID(of: pid) { everHadWindows.remove(.bundle(id)) }
            everHadWindows.remove(.process(pid))
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
            fullscreenWatch.confirm()
            refreshFullscreenState()
            claimVisibleWindows()
        }
        // 预判全屏动作，抢在系统的转场快照之前隐藏
        fullscreenWatch.onPredict = { [weak self] in self?.hidden = true }
        fullscreenWatch.onTimeout = { [weak self] in
            guard let self else { return }
            hidden = inFullscreenSpace
        }
        fullscreenWatch.start()
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
        refreshFullscreenState()
        refreshFrontWindow()
        refreshTrash()
        rebuildItems()
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
        windows = store.windows
        rebuildItems()
        sampleBackdrop()
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

    // MARK: 全屏自动隐藏 / 触底唤出（计划书 §4）
    //
    // 进入 / 退出原生全屏都会切换 Space，activeSpaceDidChange 因此是完备的触发点，
    // 不需要轮询。

    /// 唤出判定带：鼠标压到屏幕底边这么近才算
    private static let revealBand: CGFloat = 2
    /// 停留时长。触底是个高频误触的位置——全屏视频的控制条就在那儿。
    private static let dwellDuration: TimeInterval = 0.2

    private func refreshFullscreenState() {
        guard let fullscreen = SkyLight.activeSpaceIsFullscreen else {
            // SLSSpaceGetType 不可用。不静默当成「不是全屏」——那会让 bar 在全屏下一直挡着。
            Timeline.log("⚠️ SLSSpaceGetType 不可用，全屏自动隐藏关闭：\(SkyLight.missingSymbols)")
            return
        }
        guard fullscreen != inFullscreenSpace else { return }
        inFullscreenSpace = fullscreen
        hidden = fullscreen
        if !fullscreen {
            dwell?.cancel()
            dwell = nil
        }
        updateMouseMonitor()
        // 切了 Space，条底下就是另一套窗口了
        sampleBackdrop()
    }

    /// 盯着指针有两个用处：全屏下的触底唤出，多屏时的搬屏。都用不上就撤掉监听。
    private func updateMouseMonitor() {
        let needed = inFullscreenSpace || NSScreen.screens.count > 1
        if needed {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                self?.handleMouseMoved()
            }
        } else {
            mouseMonitor.map(NSEvent.removeMonitor)
            mouseMonitor = nil
            dwell?.cancel()
            dwell = nil
            moveDwell?.cancel()
            moveDwell = nil
        }
    }

    /// 屏幕接上或拔掉了。
    func screensChanged() {
        updateMouseMonitor()
    }

    private func handleMouseMoved() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let y = point.y - screen.frame.minY
        followPointer(to: screen, atBottom: y <= Self.revealBand)
        // 以下只在全屏 Space 里成立：非全屏时条常驻，指针离开底边不该把它收起来
        guard inFullscreenSpace else { return }
        if hidden {
            guard y <= Self.revealBand else { dwell?.cancel(); dwell = nil; return }
            guard dwell == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                dwell = nil
                hidden = false
                sampleBackdrop()
            }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDuration, execute: work)
        } else if y > BarMetrics.bottomGap + BarMetrics.barHeight + 12 {
            dwell?.cancel()
            dwell = nil
            hidden = true
        }
    }

    /// 条搬到指针所在的那块屏。手势与系统程序坞一致：指针压到那块屏的底边并停一下才搬，
    /// 路过不算——否则光是把鼠标划过去，条就跟着跑了。
    private func followPointer(to screen: NSScreen, atBottom: Bool) {
        guard atBottom, displayID(screen) != maximizer.barDisplay else {
            moveDwell?.cancel()
            moveDwell = nil
            return
        }
        guard moveDwell == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            moveDwell = nil
            onFollowScreen?(screen)
        }
        moveDwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDuration, execute: work)
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

    // MARK: 布局

    func layout() -> BarLayout {
        let layout = makeLayout(items: barItems, availableWidth: availableWidth,
                                overflowing: overflowing,
                                recency: { [lastActive] in lastActive[$0] ?? 0 },
                                alwaysFoldsTabs: pins.foldsTabs, wasFolded: foldedTabs)
        // 迟滞要记住上一帧收了几个。不是 @Published：它只是降级阶梯的输入，
        // 变了不需要重画，写成 @Published 会在渲染里改状态、招来一次多余的重算。
        // 这一帧从溢出区回到条上的是哪几个。视图据此让它们从溢出入口那儿飞出来。
        let inside = Set(layout.overflow.map(\.id))
        justReturned = overflowed.subtracting(inside)
        overflowed = inside
        overflowing = layout.overflow.count
        foldedTabs = layout.foldsTabs
        // 降级档位变了记一笔。阈值与迟滞的余量都是 §9 的待调参项，要靠实机读数来定。
        let tier = "\(layout.metrics.icon)/\(layout.metrics.labelCap)/\(layout.overflow.count)"
            + (layout.foldsTabs ? "T" : "")
        if tier != loggedTier {
            loggedTier = tier
            Timeline.log(String(format: "降级  可用 %.0f  内容 %.0f  图标 %.1f  标题上限 %.0f  溢出 %d  标签%@",
                                availableWidth, layout.barWidth, layout.metrics.icon,
                                layout.metrics.labelCap, layout.overflow.count,
                                layout.foldsTabs ? "收拢" : "展开"))
        }
        return layout
    }
    private var overflowing = 0
    private var overflowed: Set<CGWindowID> = []
    private var foldedTabs = false
    /// 上一帧还在溢出区、这一帧回到条上的格子。与 `overflowing` 一样不是 @Published：
    /// 它只在渲染当次被读一遍，发布出去只会招来一次多余的重算。
    private(set) var justReturned: Set<CGWindowID> = []
    private var loggedTier = ""

    private func rebuildItems() {
        // 开出窗口即到达，弹跳该收了——但要等这一轮跳完，见 landBounce
        for id in windows.compactMap(\.bundleID) where launching.contains(id) { landBounce(id) }
        for window in windows {
            everHadWindows.insert(window.bundleID.map(AppKey.bundle) ?? .process(window.pid))
        }
        // 「保留」只给 regular App——这正是系统程序坞自己的判据：LSUIElement（accessory）
        // 的 App 从来不进程序坞。只判「进程还活着」的后果是菜单栏 App 开一次面板就永久占位
        // （Stats 的弹窗、调度中心里的程序坞、Clash Verge 关掉窗口之后）。
        //
        // 注意这不影响「有窗口时露面」：accessory App 的真窗口照常进条（§4），
        // 变的只是窗口全关之后不再替它守位置。
        let retained = everHadWindows.filter {
            guard case .bundle(let id) = $0 else { return false }
            return NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains { $0.activationPolicy == .regular }
        }
        // 正在启动的 App 也占一个位置，哪怕它既没被固定、这个会话里也还没开过窗口——
        // 否则「启动中」这个状态无处可画，弹跳等于不存在。系统程序坞也是这么做的：
        // 启动的一瞬间就插一格进去，窗口出来之后原地变成它的窗口格（id 不变，见 BarItem.id）。
        let starting = launching.map(AppKey.bundle)
        barItems = makeBarItems(windows: windows, pins: pins, notice: notice,
                                retained: retained.union(starting), clusters: clusters,
                                order: order,
                                labels: labelWidths, recency: { lastActive[$0] ?? 0 })
    }

    private var notice: String? {
        if !accessibility { return "需要「辅助功能」权限" }
        if !screenRecording { return "需要「屏幕录制」权限" }
        return nil
    }

    // MARK: 固定与非窗口区（计划书 §3 / M3）

    func togglePin(_ bundleID: String) {
        pins.isPinned(bundleID) ? pins.unpin(bundleID) : pins.pin(bundleID)
        rebuildItems()
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
        rebuildItems()
    }

    func removeFolder(_ url: URL) {
        pins.removeFolder(url)
        rebuildItems()
    }

    /// 点击格子：召回。后台标签页没有 AX 元素，改按标签栏上的那一项。
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

    /// 铺满 / 还原。计划书 §3「接管最大化」的自有入口之一，从窗口格的右键菜单进入。
    func fill(_ window: IndexedWindow) {
        maximizer.toggle(window)
    }

    /// bar 所在的屏。铺满与纠正只在这块屏上扣除 bar 的高度。
    /// 视图量出玻璃条的位置后报上来，供背景亮度采样定位
    func setBarFrame(_ rect: CGRect) {
        guard rect != barFrame else { return }
        barFrame = rect
        sampleBackdrop()
    }

    func setRootOffset(_ offset: CGPoint) {
        rootOffset = offset
    }

    /// 浮层出现 / 移动时报上来，消失时报 nil
    func setFloatFrame(_ rect: CGRect?) {
        guard rect != floatFrame else { return }
        floatFrame = rect
        sampleBackdrop()
    }

    /// 采一次条与浮层玻璃板的亮度。单次约 35ms，异步；`BackdropSensor` 内部有 1 秒去抖。
    /// 采的是容器内侧那条纯玻璃，位置由 `BackdropSensor.band` 从容器矩形算出。
    private func sampleBackdrop() {
        // 滑动途中条不在位，这时抓到的是它还没盖住的桌面
        guard !hidden, !sliding, let display = maximizer.barDisplay else { return }
        if barFrame != .zero {
            backdrop.sample(probe: probe(barFrame), on: display)
        }
        if let floatFrame {
            floatBackdrop.sample(probe: probe(floatFrame), on: display)
        }
    }

    /// 视图报上来的是根坐标系里的容器矩形，先平移到屏幕坐标，再交给采样器。
    /// 条、预览卡、簇面板三块玻璃用的是同一个圆角。
    private func probe(_ rect: CGRect) -> CGRect {
        BackdropSensor.probe(in: rect.offsetBy(dx: rootOffset.x, dy: rootOffset.y),
                             cornerRadius: BarMetrics.barRadius)
    }

    func setBarDisplay(_ display: CGDirectDisplayID?) {
        let changed = maximizer.barDisplay != display
        maximizer.barDisplay = display
        corrector.barDisplay = display
        // 换了屏，条底下就是另一块桌面了
        if changed { sampleBackdrop() }
    }

    /// 条滑回来大约要这么久。采样得等它落位。
    private static let slideDuration: TimeInterval = 0.36

    func setSliding(_ value: Bool) {
        sliding = value
        guard !value else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration) { [weak self] in
            self?.sampleBackdrop()
        }
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
        rebuildItems()
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
        rebuildItems()
    }

    /// 从簇里移出一个窗口。移出后只剩一个成员的簇会自动解散。
    func detachFromCluster(_ window: CGWindowID) {
        clusters.detach(window)
        rebuildItems()
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
        rebuildItems()
    }

    func recolorCluster(_ id: Int, to color: ClusterColor) {
        clusters.recolor(id, to: color)
        rebuildItems()
    }

    func toggleClusterName(_ id: Int) {
        clusters.toggleName(id)
        publish()
    }

    func dissolveCluster(_ id: Int) {
        clusters.dissolve(id)
        rebuildItems()
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
        rebuildItems()
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
    func launch(_ app: DormantApp) {
        guard let url = app.url else {
            report("无法打开此 App", "它可能已被移除或重新命名。")
            return
        }
        startBounce(app.bundleID)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 弹跳的正常终止条件是「这个 App 有窗口了」（见 `rebuildItems`）。但 App 可能启动失败，
    /// 也可能压根不开窗口——动画必须有个兜底的终止条件。
    private static let bounceTimeout: TimeInterval = 10

    private func startBounce(_ bundleID: String) {
        guard !launching.contains(bundleID) else { return }
        bounceStarted[bundleID] = Date()
        // 条上要先有这一格才弹得起来，所以插完集合必须立刻重排（见 rebuildItems）
        launching.insert(bundleID)
        rebuildItems()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bounceTimeout) { [weak self] in
            self?.landBounce(bundleID)
        }
    }

    /// 让当前这一轮跳完再落地。中途撤掉 `bouncing`，关键帧会就地停住，图标卡在半空。
    private func landBounce(_ bundleID: String) {
        guard let started = bounceStarted[bundleID], landing.insert(bundleID).inserted else { return }
        let elapsed = Date().timeIntervalSince(started)
        let rest = LaunchBounce.cycle - elapsed.truncatingRemainder(dividingBy: LaunchBounce.cycle)
        DispatchQueue.main.asyncAfter(deadline: .now() + rest) { [weak self] in
            guard let self else { return }
            landing.remove(bundleID)
            bounceStarted[bundleID] = nil
            guard launching.remove(bundleID) != nil else { return }
            rebuildItems()
        }
    }

    // MARK: 拖入文件
    //
    // 落点由视图侧登记（SwiftUI 根坐标系），命中判定与执行都在这里，
    // 因为收拖放的是面板的 contentView，它只知道坐标。

    /// 可接收文件的项：项 id -> 它在面板里的位置
    private var dropZones: [String: CGRect] = [:]
    /// 正被拖拽悬停的项——不给高亮的话，用户不知道松手会掉进哪儿
    @Published private(set) var fileDropTarget: String?

    func setDropZone(_ id: String, _ rect: CGRect?) {
        if let rect { dropZones[id] = rect } else { dropZones[id] = nil }
    }

    func dropZone(at point: CGPoint) -> String? {
        dropZones.first { $0.value.contains(point) }?.key
    }

    func setFileDropTarget(_ id: String?) {
        guard fileDropTarget != id else { return }
        fileDropTarget = id
    }

    /// 松手。目标是项 id：垃圾桶或某个固定文件夹。
    @discardableResult
    func acceptDrop(_ id: String, _ urls: [URL]) -> Bool {
        if id == "trash" {
            moveToTrash(urls)
            return true
        }
        guard let folder = pins.folders.first(where: { "folder.\($0.path)" == id }) else {
            Timeline.log("⚠️ 拖放目标 \(id) 已不在条上")
            return false
        }
        move(urls, into: folder)
        return true
    }


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
        for item in barItems {
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
