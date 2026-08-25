import AppKit
import DocklineCore
import SwiftUI

/// 一条 bar 的模型：版面、明暗、隐藏、溢出、落点——全都是「这块屏上的」事情。
/// 窗口索引、固定项、编组、顺序这些与屏无关的东西在 `World` 里，这里只读不改
/// （计划书 §6 M5：对象全局，交互就地）。
final class BarModel: ObservableObject {
    let world: World

    /// bar 上的顶层项。在数据变化时算一次，不在视图 body 里算——
    /// makeBarItems 会更新顺序记忆并落盘，那不该是渲染的副作用。
    @Published private(set) var barItems: [BarItem] = []
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
    /// 调度中心期间让位。它是这套压制里的逃生口：MC 一开系统程序坞无条件出现，
    /// 而我们的面板浮在它上面，不让开就把逃生口挡死了。
    @Published private(set) var yielding = false
    /// 屏幕可见宽度，宽度降级阶梯的分母
    var availableWidth: CGFloat = 1440

    private let backdrop = BackdropSensor(name: "条")
    private let floatBackdrop = BackdropSensor(name: "浮层")
    /// 玻璃条在根坐标系里的位置，由视图报上来
    private var barFrame: CGRect = .zero
    /// 当前浮层在根坐标系里的位置。nil = 没有浮层。
    private var floatFrame: CGRect?
    /// 根坐标系 → 所在屏幕左上原点坐标 的平移量，由 `BarPanel` 报上来
    private var rootOffset: CGPoint = .zero
    /// 这条 bar 所在的屏。
    private(set) var display: CGDirectDisplayID?

    /// 该把条搬到哪块屏。面板的几何归 BarPanel 管，这里只发信号。
    var onFollowScreen: ((NSScreen) -> Void)?
    /// 浮层要不要用到条以上的空间。面板的几何同样归 BarPanel 管。
    var onFloatRoom: ((Bool) -> Void)?
    private var roomRelease: DispatchWorkItem?
    private var dwell: DispatchWorkItem?
    private var moveDwell: DispatchWorkItem?
    private var inFullscreenSpace = false
    /// event tap 为防转场闪烁而预先藏过条；Space 通知到达后要无条件校正一次可见性。
    private var fullscreenPredictionPending = false

    init(world: World) {
        self.world = world
        // 明暗翻转要过渡，不能一帧切过去——整条 bar 的文字同时换色，硬切很扎眼
        backdrop.onChange = { [weak self] scheme in
            withAnimation(.easeInOut(duration: 0.15)) { self?.backdropScheme = scheme }
        }
        floatBackdrop.onChange = { [weak self] scheme in
            withAnimation(.easeInOut(duration: 0.15)) { self?.floatScheme = scheme }
        }
        world.register(self)
    }

    // MARK: 版面

    func rebuildItems() {
        barItems = makeBarItems(windows: world.windows, pins: world.pins, notice: world.notice,
                                retained: world.retainedApps, clusters: world.clusters,
                                order: world.order, labels: world.labelWidths,
                                recency: { [world] in world.lastActive[$0] ?? 0 })
    }

    func layout() -> BarLayout {
        let layout = makeLayout(items: barItems, availableWidth: availableWidth,
                                overflowing: overflowing,
                                recency: { [world] in world.lastActive[$0] ?? 0 },
                                alwaysFoldsTabs: world.pins.foldsTabs, wasFolded: foldedTabs)
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

    /// 条上现有的编组，供右键菜单列出可加入的目标。
    var clusterChoices: [(id: Int, name: String)] {
        barItems.compactMap {
            guard case .cluster(let cluster) = $0 else { return nil }
            return (cluster.id, cluster.heading)
        }
    }

    // MARK: 全屏自动隐藏 / 触底唤出（计划书 §4）
    //
    // 进入 / 退出原生全屏都会切换 Space，activeSpaceDidChange 因此是完备的触发点，
    // 不需要轮询。

    /// 唤出判定带：鼠标压到屏幕底边这么近才算
    private static let revealBand: CGFloat = 2
    /// 停留时长。触底是个高频误触的位置——全屏视频的控制条就在那儿。
    private static let dwellDuration: TimeInterval = 0.2

    /// Space 换了。预判过的那一次要在这里对账——预判发生在另一块显示器时，
    /// 本屏 Space 根本没变，条却已经被预先藏过。
    func activeSpaceChanged() {
        let predicted = fullscreenPredictionPending
        fullscreenPredictionPending = false
        refreshFullscreenState(reconcilePrediction: predicted)
    }

    func predictFullscreen() {
        fullscreenPredictionPending = true
        hidden = true
    }

    func fullscreenPredictionTimedOut() {
        fullscreenPredictionPending = false
        hidden = inFullscreenSpace
    }

    func refreshFullscreenState(reconcilePrediction: Bool = false) {
        guard let display,
              let fullscreen = SkyLight.activeSpaceIsFullscreen(on: display) else {
            // Managed Display Spaces 不可用。不静默当成「不是全屏」——那会让 bar 在全屏下一直挡着。
            Timeline.log("⚠️ 逐屏 Space 类型不可用，全屏自动隐藏关闭：\(SkyLight.missingSymbols)")
            return
        }
        guard fullscreen != inFullscreenSpace else {
            if reconcilePrediction { hidden = fullscreen }
            return
        }
        inFullscreenSpace = fullscreen
        hidden = fullscreen
        if !fullscreen {
            dwell?.cancel()
            dwell = nil
        }
        world.updateMouseMonitor()
        // 切了 Space，条底下就是另一套窗口了
        sampleBackdrop()
    }

    /// 盯着指针有两个用处：全屏下的触底唤出，多屏时的搬屏。都用不上就不必挂监听。
    var wantsPointer: Bool { inFullscreenSpace || NSScreen.screens.count > 1 }

    /// 屏幕接上或拔掉了。
    func screensChanged() {
        world.updateMouseMonitor()
    }

    /// 监听撤掉了，正在计时的停留判定也要一起作废——否则它还会再触发一次，
    /// 而那一次背后已经没有指针位置了。
    func cancelPointerDwell() {
        dwell?.cancel()
        dwell = nil
        moveDwell?.cancel()
        moveDwell = nil
    }

    func pointerMoved(to point: CGPoint) {
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
        guard atBottom, displayID(screen) != display else {
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

    // MARK: 几何与背景亮度

    /// 视图量出玻璃条的位置后报上来，供背景亮度采样定位
    func setBarFrame(_ rect: CGRect) {
        guard rect != barFrame else { return }
        barFrame = rect
        sampleBackdrop()
    }

    func setRootOffset(_ offset: CGPoint) {
        guard offset != rootOffset else { return }
        rootOffset = offset
        // 条与浮层的矩形都是根坐标系里的量，根一挪它们当场过期。留着的话下一次采样会把
        // 新的平移量加到旧的矩形上，采到屏幕上的另一块地方——面板按需改高度时每次都会撞上。
        barFrame = .zero
        floatFrame = nil
    }

    /// 浮层出现 / 移动时报上来，消失时报 nil
    func setFloatFrame(_ rect: CGRect?) {
        guard rect != floatFrame else { return }
        floatFrame = rect
        sampleBackdrop()
    }

    /// 条上有悬停或浮层，条以上那块空间就要用起来了。
    ///
    /// 长高是立刻的——浮层要先有地方才画得下；落回则等一下：指针在相邻格子之间挪动时
    /// 悬停会短暂落空，立刻收回会把面板一路撑起放下。
    private static let roomReleaseDelay: TimeInterval = 0.4

    func needsFloatRoom(_ needed: Bool) {
        roomRelease?.cancel()
        roomRelease = nil
        guard !needed else {
            onFloatRoom?(true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            roomRelease = nil
            onFloatRoom?(false)
        }
        roomRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.roomReleaseDelay, execute: work)
    }

    /// 采一次条与浮层玻璃板的亮度。单次约 35ms，异步；`BackdropSensor` 内部有 1 秒去抖。
    /// 采的是容器内侧那条纯玻璃，位置由 `BackdropSensor.band` 从容器矩形算出。
    func sampleBackdrop() {
        // 滑动途中条不在位，这时抓到的是它还没盖住的桌面
        guard !hidden, !sliding, !yielding, let display else { return }
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

    /// bar 所在的屏。铺满与纠正只在这块屏上扣除 bar 的高度。
    func setBarDisplay(_ display: CGDirectDisplayID?) {
        let changed = self.display != display
        self.display = display
        world.maximizer.barDisplay = display
        world.corrector.barDisplay = display
        // 每块显示器有自己当前的 Space。条搬屏时必须立刻切换到那块屏的全屏状态。
        if changed { refreshFullscreenState() }
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

    func setYielding(_ value: Bool) {
        guard yielding != value else { return }
        yielding = value
        Timeline.log(value ? "调度中心打开，条让位" : "调度中心关闭，条回位")
        // 让回来的时候条底下压的常常已经不是原来那块东西了
        if !value { sampleBackdrop() }
    }

    // MARK: 拖入文件
    //
    // 落点由视图侧登记（SwiftUI 根坐标系），命中判定与执行都在这里，
    // 因为收拖放的是面板的 contentView，它只知道坐标。

    /// 可接收文件的项：项 id -> 它在面板里的位置
    private var dropZones: [String: CGRect] = [:]
    /// 右键命中区。与拖放区分开：每一格都能有菜单，拖放只认文件夹与废纸篓。
    private var menuZones: [String: CGRect] = [:]
    /// 正被拖拽悬停的项——不给高亮的话，用户不知道松手会掉进哪儿
    @Published private(set) var fileDropTarget: String?

    func setDropZone(_ id: String, _ rect: CGRect?) {
        if let rect { dropZones[id] = rect } else { dropZones[id] = nil }
    }

    func dropZone(at point: CGPoint) -> String? {
        dropZones.first { $0.value.contains(point) }?.key
    }

    func setMenuZone(_ id: String, _ rect: CGRect?) {
        if let rect { menuZones[id] = rect } else { menuZones[id] = nil }
    }

    func menuZone(at point: CGPoint) -> String? {
        menuZones.first { $0.value.contains(point) }?.key
    }

    func barContains(_ point: CGPoint) -> Bool {
        barFrame.contains(point)
    }

    func setFileDropTarget(_ id: String?) {
        guard fileDropTarget != id else { return }
        fileDropTarget = id
    }

    /// 松手。目标是项 id：垃圾桶或某个固定文件夹。
    @discardableResult
    func acceptDrop(_ id: String, _ urls: [URL]) -> Bool {
        if id == "trash" {
            world.moveToTrash(urls)
            return true
        }
        guard let folder = world.pins.folders.first(where: { "folder.\($0.path)" == id }) else {
            Timeline.log("⚠️ 拖放目标 \(id) 已不在条上")
            return false
        }
        world.move(urls, into: folder)
        return true
    }
}
