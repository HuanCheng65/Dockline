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
    /// 两项权限有没有到手。它们**没有通知可订阅**，只能跟着对账每两秒复查一次，
    /// 因此写入必须走 `note`：同一个值再写一遍要什么都不发生。
    ///
    /// 先前是可直接赋值的 `@Published`，`didSet` 里无条件重排。而赋同一个值照样触发
    /// `didSet` 与 `objectWillChange`，于是每两秒白重排两次，每次都要向 LaunchServices
    /// 逐个 App 同步问一遍 activationPolicy（见 `retainedApps`）——实测这两下空转
    /// 占掉主线程 3% 的 CPU，而它们什么都没做。
    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false

    func note(accessibility granted: Bool, screenRecording recording: Bool) {
        guard granted != accessibility || recording != screenRecording else { return }
        accessibility = granted
        screenRecording = recording
        rebuild()
    }
    /// 当前前台窗口——底色「亮底」档的唯一依据
    @Published private(set) var frontWindow: CGWindowID? { didSet { noteFrontSeen() } }
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
    /// 活动状态。计划书 §3。挂点见 `StatusTarget`：来源现在只产出 App 级，
    /// 窗口级要等会话与窗口的绑定做出来。
    @Published private(set) var sessions: [StatusTarget: Session] = [:]
    /// 此刻在放什么。全系统只有一个「正在播放」，所以这里就一份，不按格子分。
    @Published private(set) var nowPlaying: NowPlaying?
    /// 发声那个 App 的进程号。由 `nowPlaying.bundleID` 解析而来，解析不到就没有落点。
    private(set) var mediaPID: pid_t?
    /// 按下上/下一首之后多久之内到达的换歌算作那一次按键的结果。
    private static let skipWindow: TimeInterval = 1.5

    /// 均衡器的实时电平。**不走 `@Published`**：它一秒变三十次，进了 bar 的模型就是
    /// 每秒把整条条重建三十遍。均衡器那个视图自己读它。
    let mediaLevels = MediaLevels()

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
    private var nameCache: [URL: String] = [:]
    private var bundleURLCache: [pid_t: URL] = [:]

    /// 写别人家窗口几何的唯一出口。三处摆位（铺满 / 分屏、搬到另一块屏、结果纠正）
    /// 全部从它走，报备因此不会漏。见 `WindowPlacer`。
    private let placer = WindowPlacer()
    lazy var maximizer = Maximizer(placer: placer)
    lazy var corrector = TilingCorrector(placer: placer)
    /// 拖格子分屏时画在桌面上的那块落点
    let splitPreview = SplitPreview()
    /// nil = 快捷键没注册上（组合被别的程序占用）。设置页据此说明情况。
    private(set) var fillHotKey: HotKey?

    private let tilePlugins = DockTilePlugins()
    private let badgeReader = BadgeReader()
    private let settings = SettingsWindowController()
    private var pendingApps = Set<pid_t>()
    private var coalesceScheduled = false
    /// 上一次报过的「不应答 App」名单，用来去重
    private var lastStalledReport: [String] = []
    private var suppressReadySync = false
    private let fullscreenWatch = FullscreenWatch()
    private let missionControl = MissionControlWatch()
    private let sessionCenter = SessionCenter()
    private let askServer = AskServer()
    private let nowPlayingReader = NowPlayingReader()
    private lazy var mediaTap = MediaTap(levels: mediaLevels)
    /// 我们自己最近发出的一条上/下一首，以及发出的时刻。换歌方向的唯一可靠来源。
    private var lastSkip: (command: MediaCommand, at: Date)?
    private var mouseMonitor: Any?

    /// 这一格的终态已被用户看见。未读语义的出口——终态不自行消失，因为用户没看到
    /// 就消失的通知等于没有发出过。只撤终态，运行中与等待中的不动。
    /// 这一格的终态已被用户看见。**目标由这里判**，不由调用方判：窗口级还是 App 级
    /// 与上面那条查找是同一条规则，让点击那一侧再判一次就是第六份抄写。
    /// 一个此刻没有窗口的 App 上的状态。
    ///
    /// **窗口全关不等于事情结束。** 播放器关掉窗口继续在后台放歌是常态，而那一格还在——
    /// 它是窗口全关之后留下的占位槽（计划书 §6 M5）。先前占位槽那一支把状态直接写死成
    /// `nil`，于是关掉播放器的窗口，条上就什么都不说了。
    ///
    /// 优先级与有窗口那条一致：**任务型压过常驻型**。
    func status(app pid: pid_t?) -> CellStatus? {
        guard let pid else { return nil }
        if let session = sessions[.app(pid)] { return .session(session) }
        guard let playing = nowPlaying, mediaPID == pid else { return nil }
        return .media(playing)
    }

    func markStatusSeen(window id: CGWindowID, of pid: pid_t) {
        sessionCenter.markSeen(sessions[.window(id)] != nil ? .window(id) : .app(pid))
    }

    /// 终态的「看见」只有这一条出口：**那扇窗口到了前台**。
    ///
    /// 点条上那一格、⌘Tab 过去、直接点窗口、召回——用户能到达那扇窗口的路有好几条，
    /// 而它们最终都汇到「谁在前台」这一个值上。判定因此挂在这个值上，不逐条去接：
    /// 漏掉其中一条的代价是一条永远退不下去的终态，而这正是先前只接了「点格子」
    /// 那一条时的样子。
    ///
    /// 上报变化时也要问一次：任务结束的那一刻用户可能正看着那扇窗口，此时前台没有变过，
    /// 而「已经在看着」与「刚切过去」是同一件事。
    private func noteFrontSeen() {
        guard let id = frontWindow, let pid = windows.first(where: { $0.id == id })?.pid
        else { return }
        markStatusSeen(window: id, of: pid)
    }

    /// 这一格该显示谁的会话。窗口级的先问——它更精确；问不到再退回 App 级，
    /// 而 **App 级的东西只挂在该 App 在条上的第一格**，与未读角标同一条规则。
    ///
    /// **这条规则只写在这里。** 它原先抄在五处，其中三处漏掉了「第一格」那一半，
    /// 于是同一个 App 的第二扇窗口悬停时也会浮出它的会话。
    func session(window id: CGWindowID, of pid: pid_t, leads: Bool) -> Session? {
        if let own = sessions[.window(id)] { return own }
        return leads ? sessions[.app(pid)] : nil
    }

    /// 这一格此刻显示什么。
    ///
    /// **任务型压过常驻型。** 一格上同时有会话和播放是极少见的（两者绑的是不同的
    /// App），真撞上时该让位的是播放：它不会结束，等会话停了自然回来，而反过来会把
    /// 一件正在等你的事盖住。
    ///
    /// 播放挂在发声那个 App 的第一格上，与 App 级会话同一条规则。
    func status(window id: CGWindowID, of pid: pid_t, leads: Bool) -> CellStatus? {
        if let session = session(window: id, of: pid, leads: leads) { return .session(session) }
        guard leads, let playing = nowPlaying, mediaPID == pid else { return nil }
        return .media(playing)
    }

    /// 用户在面板上批了或驳了一次授权（实时状态设计 §4.7）。
    func answerAsk(_ id: UUID, allow: Bool) {
        sessionCenter.answer(id, allow: allow)
    }

    /// 用户在面板上按了播放控制。
    func sendMedia(_ command: MediaCommand) {
        if command == .next || command == .previous { lastSkip = (command, Date()) }
        nowPlayingReader.send(command)
    }

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

    /// 搬过去之后它会落在哪儿。AppKit 坐标系，nil = 读不到它现在的几何。
    ///
    /// **预览与写入读同一个函数**：拖格子拖到另一块屏时，浮起来的那块玻璃显示的就是
    /// 这个矩形。各算一遍的话，看到的和落下去的迟早会不一样（分屏那边已经栽过一次）。
    func landing(_ window: IndexedWindow, on target: NSScreen) -> CGRect? {
        guard let element = window.element else { return nil }
        return try? landing(element, on: target)
    }

    private func landing(_ element: AXUIElement, on target: NSScreen) throws -> CGRect? {
        // 读的是扣掉 bar 的那一份，不是 visibleFrame：这一步同样是我们自己在摆窗口，
        // 没有理由把它摆到自己的条底下去。用 visibleFrame 时，铺满的窗口搬过去正好
        // 落在目标屏的落点上，还会顺带把结果纠正引进来（见 `TilingCorrector.weWrote`）。
        let area = maximizer.area(on: target)
        let from = try maximizer.area(on: screen(of: element))
        guard let rect = axRect(element) else { return nil }
        let frame = flipY(rect)
        let ratio = CGPoint(x: from.width > 0 ? (frame.minX - from.minX) / from.width : 0,
                            y: from.height > 0 ? (frame.minY - from.minY) / from.height : 0)
        let size = CGSize(width: min(frame.width, area.width),
                          height: min(frame.height, area.height))
        let origin = CGPoint(
            x: min(max(area.minX + ratio.x * area.width, area.minX), area.maxX - size.width),
            y: min(max(area.minY + ratio.y * area.height, area.minY), area.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    /// 把一个窗口搬到另一块屏（计划书 §6 M5「移到此显示器」）。
    ///
    /// 尺寸照旧，位置按它在原屏可见区域里的相对位置落下去，装不下就夹进目标的可见区域。
    /// 写位置用的是接管最大化那套 AX 双写——不擅自动 Space，也不碰窗口层级。
    func move(_ window: IndexedWindow, to display: CGDirectDisplayID,
              using override: AXUIElement? = nil) {
        guard let element = override ?? window.element else {
            Timeline.log("⚠️ 移到显示器跳过 wid \(window.id)：窗口在其他 Space，尚无 AX 引用")
            return
        }
        guard let target = NSScreen.screens.first(where: { displayID($0) == display }) else {
            Timeline.log("⚠️ 移到显示器跳过 wid \(window.id)：屏 \(display) 已经不在了")
            return
        }
        do {
            guard let goal = try landing(element, on: target) else { throw FillError.noGeometry }
            let outcome = try placer.place(element, to: flipY(goal), wid: window.id)
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
            sessionCenter.remove(pid: pid)
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
        // 预判全屏动作，抢在系统的转场快照之前隐藏。点绿灯时落点就在目标窗口上，
        // 冲着哪块屏去是确定的，只藏那一条；⌃⌘F 没有落点，判不出来，只能每条都先藏，
        // 随后各自按本屏的 Space 类型校正回来（见 `BarModel.activeSpaceChanged`）。
        fullscreenWatch.onPredict = { [weak self] display in
            guard let self else { return }
            for bar in bars where display == nil || bar.display == display {
                bar.predictFullscreen()
            }
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
        sessionCenter.onChange = { [weak self] in
            guard let self else { return }
            sessions = sessionCenter.display
            noteFrontSeen()
        }
        nowPlayingReader.onChange = { [weak self] playing in
            guard let self else { return }
            // bundleID 要当场解析成进程号：格子是按 pid 认的，而同一个 bundle 可能
            // 根本没在跑（播放源刚退出时就会这样），那时它没有落点。
            let pid = playing.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID)
                    .first?.processIdentifier
            }
            var next = pid == nil ? nil : playing
            // 换歌的方向。MediaRemote 不说这是「下一首」还是「跳到某一首」，只能推。
            //
            // 能拿到的只有一条可靠信号：我们自己的上/下一首刚被按过。其余一律判向前——
            // 自动续播占绝大多数，而在少数「你在播放器里直接点了另一首」的情况下猜错，
            // 代价只是动画方向不对。**上一首多数时候根本不换歌**（播放器普遍是位置超过
            // 三秒就从头开始），所以判定挂在歌的身份变了这个条件上，不挂在指令上。
            if next?.track != nowPlaying?.track, let skip = lastSkip,
               Date().timeIntervalSince(skip.at) < Self.skipWindow {
                next?.advance = skip.command == .previous ? .backward : .forward
            }
            // 桥在同一个状态上可能连发好几条（几个通知先后到达）。原样往下传会让整条 bar
            // 白重排几次，而这一档本来就不该有任何动静。
            guard next != nowPlaying else { return }
            mediaPID = pid
            nowPlaying = next
            // 换了播放源就把 tap 挪过去。停着的时候也照挂——重挂要建 tap、建聚合设备，
            // 起播不该等这一轮；但那台设备的 IO 会停下来（见 `MediaTap.follow`）。
            mediaTap.follow(next?.bundleID, playing: next?.playing == true)
            guard let next else {
                Timeline.log("播放  没有播放源")
                return
            }
            Timeline.log("播放  \(next.bundleID) pid \(pid ?? 0)  "
                         + "\(next.playing ? "在放" : "停着")  \(next.title ?? "—")")
        }
        nowPlayingReader.start()
        // 上次绑的那扇窗口还在，就原样沿用、不重新判断。复核只发生在会话头一次上报、
        // cwd 变了、或那扇窗口没了这三种时候——任务结束那一刻的焦点已经不是它了。
        sessionCenter.bind = { [weak self] host, cwd, keeping in
            guard let self else { return SessionBinding.Outcome(target: .app(host), why: nil) }
            if case .window(let id) = keeping, windows.contains(where: { $0.id == id }) {
                return SessionBinding.Outcome(target: .window(id), why: nil)
            }
            return SessionBinding.resolve(host: host, cwd: cwd,
                                          windows: windows, front: frontWindow)
        }
        sessionCenter.start()
        // 就地授权走自己的一条通道：状态上报是单向的，授权要一问一答（见 `AskServer`）
        sessionCenter.onAnswer = { [weak self] id, allow, message in
            self?.askServer.answer(id, allow: allow, message: message)
        }
        sessionCenter.onDecline = { [weak self] id in self?.askServer.decline(id) }
        askServer.onAsk = { [weak self] id, payload in self?.sessionCenter.receiveAsk(id, payload) }
        askServer.onGone = { [weak self] id in self?.sessionCenter.dropAsk(id) }
        askServer.start()
        placer.onPlaced = { [weak self] wid, kind in self?.corrector.noteWrite(wid, kind) }
        corrector.enabled = pins.correctsTiling
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

    /// 手上还有没认领的窗口时，完整那一遍最长隔多久必来一次。
    private static let unclaimedSweep: TimeInterval = 10
    private var lastFingerprint: UInt64?
    private var lastFullReconcile = Date.distantPast

    /// 完整那一遍此刻还有没有它独有的活儿。
    ///
    /// 指纹只认名单。名单之外的变化——标题、边界——各有各的窗口级通知，**唯独没拿到
    /// AX 引用的窗口一条都收不到**：跨 Space 的存量窗口在被认领之前就是这样，CG 那一遍
    /// 是它们唯一的信息源。这种窗口一个都没有的时候，指纹就是完备的判据，不必再定时来。
    ///
    /// 新出现的窗口不在此列：它一出现名单就变了，指纹认得出。这里说的只是**已经知道、
    /// 却还搭不上话**的那些。
    private var hasUnclaimedWindows: Bool {
        store.windows.contains { $0.element == nil }
    }

    func reconcile() {
        // 跟着对账 tick 采一次背景亮度。这里必须是周期性的，不能只挂在事件上：
        // 条底下那个窗口自己换了内容（切页、播视频、换主题）不触发我们的任何事件，
        // 而那正是最常见的情况。单次约 35ms，异步，只在条可见时进行。
        sampleBackdrop()
        guard accessibility else { return }
        // **先花 0.2 毫秒问一句「名单有没有变」，再决定要不要花二十几毫秒去对账。**
        // 绝大多数轮次它什么都发现不了，而这个进程空置时的开销几乎全在这一遍上。
        //
        // 指纹认窗口的增减与上下屏，名单之外的变化归窗口级通知。两者合起来是完备的，
        // 除了还搭不上话的那些窗口——那才是下面这条按时扫一遍的理由，它有名有姓，
        // 不是「以防万一」。
        let fingerprint = windowListFingerprint()
        let sweep = hasUnclaimedWindows
            && Date().timeIntervalSince(lastFullReconcile) >= Self.unclaimedSweep
        guard sweep || fingerprint == nil || fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        lastFullReconcile = Date()
        let before = Set(store.windows.map(\.id))
        let changed = store.reconcile()
        diagnostics.timing = store.timing
        // 有 App 答不上 AX 就说出来。它一个就要烧掉整整一秒的超时，而这一秒是记在
        // 主线程账上的——不出声的话，症状只会以「启动卡住好几秒」的样子出现，
        // 而那个样子指不到原因。去重是因为退避期内每一轮都会重复报同一批。
        if !store.lastStalled.isEmpty, store.lastStalled != lastStalledReport {
            Timeline.log("⚠️ 这些 App 不应答 AX，暂时跳过：\(store.lastStalled.joined(separator: "、"))")
        }
        lastStalledReport = store.lastStalled
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
    ///
    /// **要记住。** 这个名字是在视图的 body 里取的，条一重排就每一项各取一次，而它走的是
    /// LaunchServices 的同步 XPC（实测这一项占掉重排开销的一成半）。名字只有用户改名时
    /// 才会变，而那时条上那一项本来就要重新出现一次。
    func displayName(of url: URL) -> String {
        if let cached = nameCache[url] { return cached }
        let name = FileManager.default.displayName(atPath: url.path)
        nameCache[url] = name
        return name
    }

    /// 这个进程的 App 包在哪儿。与图标同一个道理：也是在 body 里取的，也走 XPC。
    func bundleURL(pid: pid_t) -> URL? {
        if let cached = bundleURLCache[pid] { return cached }
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return nil }
        bundleURLCache[pid] = url
        return url
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
        icon(app: bundleURL(pid: cell.pid), bundleID: cell.bundleID)
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
    /// 这个 App 此刻有没有窗口。槽位能出现在条上就说明**本屏**没有它的窗口，
    /// 所以这里为真即「有，但都在别的屏」——指示点画成空心圈的判据。
    func hasWindows(_ app: DormantApp) -> Bool { !windowsOf(app).isEmpty }

    private func windowsOf(_ app: DormantApp) -> [IndexedWindow] {
        // 有 pid 就按 pid：同一个 App 可能开了多个实例，bundle ID 分不开它们。
        if let pid = app.pid { return windows.filter { $0.pid == pid } }
        return windows.filter { $0.bundleID == app.bundleID }
    }

    /// 这个 App 在别的屏上的窗口，供空心圈那一格的悬停浮层用。
    ///
    /// 按最近使用排：第一张就是点这一格会拿过来的那一扇，看与做因此对得上。
    func elsewhereWindows(_ key: AppKey) -> [BarWindow] {
        let mine = windows.filter { window in
            switch key {
            case .bundle(let id): return window.bundleID == id
            case .process(let pid): return window.pid == pid
            }
        }
        return mine
            .sorted { (lastActive[$0.id] ?? 0) > (lastActive[$1.id] ?? 0) }
            .map {
                BarWindow(window: $0, label: nil, labelWidth: 0,
                          key: key, appName: $0.appName, pid: $0.pid,
                          bundleID: $0.bundleID, leadsApp: false)
            }
    }

    /// 把这个 App 已有的窗口拿到这块屏来（计划书 §6 M5）。
    ///
    /// 槽位下面那个空心圈已经预告了这件事——它说的是「有窗口，但不在这块屏」，
    /// 而点一格的意思一向是「我要用它」。多扇时拿最近用过的那一扇：它最可能是
    /// 用户心里想的那个。想开一扇**新的**是另一件事，走右键的「在此显示器打开」。
    func bringHere(_ app: DormantApp, to display: CGDirectDisplayID) {
        guard let window = windowsOf(app)
            .max(by: { (lastActive[$0.id] ?? 0) < (lastActive[$1.id] ?? 0) }) else {
            Timeline.log("⚠️ 拿到本屏跳过 \(app.name)：它此刻一个窗口都没有")
            return
        }
        send(window, to: display, why: "拿到本屏")
    }

    /// 把这扇窗口搬到某块屏，并叫到前台。
    ///
    /// 三个入口共用：拖格子拖到另一块屏的条上、点那个空心圈的槽位、右键「移到显示器」。
    /// 合成一处是因为它们要处理的边界完全一样——别的 Space 上的窗口没有 AX 引用，
    /// 而挪位置和摆位一样要写它的几何；最小化的窗口挪不动，得先从最小化里出来。
    /// 分开写就会像以前那样，只有其中一条记得处理。
    func send(_ window: IndexedWindow, to display: CGDirectDisplayID, why: String = "移到显示器") {
        reach(window, on: display, why: why) { [weak self] element in
            guard let self else { return }
            // 拖过去的那条会挂着落点预览，要等窗口真的到位再让它化开——跨 Space 的窗口
            // 中间还有一次迁移，早化开就会露出「预览没了、窗口还没动」那一段。
            // 没有预览时这一句是空操作，另外两个入口因此不必各自判一遍。
            defer { splitPreview.dissolve() }
            guard let element else { return }
            guard isFullscreen(element) != true else {
                sendFullscreen(window, element: element, to: display)
                return
            }
            recall(window)
            noteActivated(window.id)
            move(window, to: display, using: element)
        }
    }

    /// 轮询的间隔，以及每一步等实际状态的上限。
    /// 全屏进出各是一段系统转场，上限要盖得住最慢的那一次，不是拿来当节拍的。
    private static let settleTick: TimeInterval = 0.04
    private static let fullscreenLimit: TimeInterval = 3

    /// 把一扇**全屏**窗口搬到另一块屏：退全屏 → 摆过去 → 重新全屏。
    ///
    /// macOS 自己没有这条路：全屏窗口独占一个 Space，而那个 Space 属于某一块屏；
    /// 用户要么手动退全屏、拖过去、再全屏，要么去调度中心里拖那张缩略图。一个动作做完
    /// 是我们能给的，代价是两段看得见的系统转场——那是这件事的真实成本，且是用户点了
    /// 才发生的。
    ///
    /// **三步之间必须等实际状态，不能靠 sleep 蒙**：退全屏是一段动画，窗口会飞回全屏之前
    /// 的位置；动画没走完就写几何，写进去的会被动画的收尾覆盖掉。摆位同理，没停稳就重新
    /// 全屏，系统会按旧位置挑屏幕。判据都是「矩形连着两次读到一样」。
    private func sendFullscreen(_ window: IndexedWindow, element: AXUIElement,
                                to display: CGDirectDisplayID) {
        guard fullscreenSettable(element) else {
            Timeline.log("⚠️ 移到显示器放弃 wid \(window.id) \(window.appName)："
                         + "它是全屏窗口，而这个 App 不让改 AXFullScreen")
            report("这个窗口挪不过去",
                   "\(window.appName) 不允许由程序改变它的全屏状态。先手动退出全屏，再移动它。")
            return
        }
        let began = Date()
        recall(window)
        noteActivated(window.id)
        setFullscreen(element, false)
        awaitStable(element, also: { isFullscreen(element) == false }) { [weak self] settled in
            guard let self else { return }
            guard settled else {
                // 停在这里，不往下走：窗口此刻要么还全屏着、要么退了全屏仍在原来那块屏上，
                // 两种都是用户认得出、也能自己接手的状态。继续摆位才会摆出个半截。
                Timeline.log("⚠️ 移到显示器中止 wid \(window.id) \(window.appName)："
                             + "等不到它退出全屏，没有再动它")
                return
            }
            move(window, to: display, using: element)
            awaitStable(element) { placed in
                guard placed else {
                    Timeline.log("⚠️ 移到显示器中止 wid \(window.id) \(window.appName)："
                                 + "退了全屏但位置一直没停稳，没有替它重新全屏")
                    return
                }
                setFullscreen(element, true)
                Timeline.log(String(format: "全屏窗口移到屏 %u  wid %u %@  用时 %.0fms",
                                    display, window.id, window.appName,
                                    Date().timeIntervalSince(began) * 1000))
            }
        }
    }

    /// 等窗口的几何停稳（可再附加一个条件）。判据是连着两次读到同一个矩形。
    ///
    /// 轮询而不是订阅，理由同 `awaitMigration`：窗口服务器不为这件事广播任何东西，
    /// 而这是用户一次显式动作里的一小段，不是常驻路径。
    private func awaitStable(_ element: AXUIElement,
                             also ready: @escaping () -> Bool = { true },
                             then body: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(Self.fullscreenLimit)
        var previous: CGRect?
        func poll() {
            if ready(), let now = axRect(element) {
                if let previous, matchesFrame(previous, now) {
                    body(true)
                    return
                }
                previous = now
            } else {
                // 条件还不成立，之前那次读数就不能拿来比：中间隔着一段没被观察到的变化
                previous = nil
            }
            guard Date() < deadline else {
                body(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTick) { poll() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTick) { poll() }
    }

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
