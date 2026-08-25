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
    /// 条此刻收着没有。触底唤出时置回 false。两种情况会让它收起来：本屏进了全屏
    /// Space（计划书 §4），或者本屏被设成自动隐藏（§6 M5）。
    @Published private(set) var hidden = false
    /// 本屏的可见性设置：false = 始终显示，true = 自动隐藏。
    private(set) var autoHides = false
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

    /// 浮层要不要用到条以上的空间。面板的几何归 BarPanel 管。
    var onFloatRoom: ((Bool) -> Void)?
    private var roomRelease: DispatchWorkItem?
    private var dwell: DispatchWorkItem?
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

    /// 标题宽度的测量缓存。每条 bar 一份：它按本屏画出来的东西剪枝，
    /// 共用一份的话每条 bar 都会把别人的量测结果剪掉。
    private let labelWidths = LabelWidths()

    /// 这一轮刚从别的屏迁过来的格子 → 它原来在哪块屏。视图据此定飞进来的方向。
    /// 新开的窗口不算——它没有来处，照旧原地生长。
    private(set) var justArrived: [CGWindowID: CGDirectDisplayID] = [:]
    /// 上一轮归本屏的窗口，用来认出这一轮新到的那些。
    private var wasMine: Set<CGWindowID> = []

    func rebuildItems() {
        let mine = Set(world.windows.filter { world.home(of: $0) == display }.map(\.id))
        justArrived = world.justMigrated.filter { !wasMine.contains($0.key) && mine.contains($0.key) }
        wasMine = mine
        barItems = makeBarItems(
            windows: world.windows, onThisDisplay: mine,
            // 固定 App 每块屏都有槽位；其余的只出现在它最后拥有窗口的那块屏上。
            dormantHere: { [world, display] key in
                key.bundleID.map(world.pins.isPinned) == true || world.home(of: key) == display
            },
            pins: world.pins, notice: world.notice, clusters: world.clusters,
            order: world.order, labels: labelWidths,
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
        hidden = shouldHide
    }

    /// 没有唤出动作时条该不该收着。
    private var shouldHide: Bool { inFullscreenSpace || autoHides }

    /// 本屏改了可见性。设置窗口走 `World`，由它转到对应的这一条。
    func setAutoHides(_ value: Bool) {
        guard autoHides != value else { return }
        autoHides = value
        hidden = shouldHide
        // 自动隐藏的条不占位——铺满不该为一条平时不在的条扣掉底部那一条
        world.refreshBarDisplays()
        world.updateMouseMonitor()
        if !hidden { sampleBackdrop() }
    }

    func refreshFullscreenState(reconcilePrediction: Bool = false) {
        guard let display,
              let fullscreen = SkyLight.activeSpaceIsFullscreen(on: display) else {
            // Managed Display Spaces 不可用。不静默当成「不是全屏」——那会让 bar 在全屏下一直挡着。
            Timeline.log("⚠️ 逐屏 Space 类型不可用，全屏自动隐藏关闭：\(SkyLight.missingSymbols)")
            return
        }
        guard fullscreen != inFullscreenSpace else {
            if reconcilePrediction { hidden = shouldHide }
            return
        }
        inFullscreenSpace = fullscreen
        hidden = shouldHide
        if !fullscreen {
            dwell?.cancel()
            dwell = nil
        }
        world.updateMouseMonitor()
        // 切了 Space，条底下就是另一套窗口了
        sampleBackdrop()
    }

    /// 盯着指针只为触底唤出。条常驻的时候一次监听都不必挂。
    var wantsPointer: Bool { shouldHide }

    /// 监听撤掉了，正在计时的停留判定也要一起作废——否则它还会再触发一次，
    /// 而那一次背后已经没有指针位置了。
    func cancelPointerDwell() {
        dwell?.cancel()
        dwell = nil
    }

    /// 只在条会自己收起来的时候成立：常驻的条，指针离开底边不该把它收起来。
    /// 指针不在本屏时同样不理会——每块屏的条各自唤出。
    func pointerMoved(to point: CGPoint) {
        guard shouldHide,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              displayID(screen) == display else { return }
        let y = point.y - screen.frame.minY
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

    // MARK: 几何与背景亮度

    /// 视图量出玻璃条的位置后报上来，供背景亮度采样定位
    func setBarFrame(_ rect: CGRect) {
        guard rect != barFrame else { return }
        barFrame = rect
        barHitFrame = anchored(rect)
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
        guard !hidden, !yielding, let display else { return }
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
        world.refreshBarDisplays()
        guard changed else { return }
        // 可见性是按屏存的，换了屏就是另一份设置
        autoHides = world.autoHides(on: display)
        hidden = shouldHide
        // 条上该有哪些窗口，是按这块屏挑出来的
        rebuildItems()
        // 每块显示器有自己当前的 Space，全屏状态要立刻切到那块屏的
        refreshFullscreenState()
        // 换了屏，条底下就是另一块桌面了
        sampleBackdrop()
    }

    func setYielding(_ value: Bool) {
        guard yielding != value else { return }
        yielding = value
        Timeline.log(value ? "调度中心打开，条让位" : "调度中心关闭，条回位")
        // 让回来的时候条底下压的常常已经不是原来那块东西了
        if !value { sampleBackdrop() }
    }

    // MARK: 命中区
    //
    // 落点由视图侧登记（SwiftUI 根坐标系，左上原点），命中判定与执行都在这里，
    // 因为收拖放与右键的是面板的 contentView，它只知道坐标。
    //
    // **一律换算成「离面板底边多远」再存。** 面板会按需长高——浮层要用到条以上的空间，
    // 而条钉在底边上，所以离底边的距离不随高度变，按左上原点存则会整体偏掉一个高度差。
    // 这不是理论问题：拖拽经过条上的格子会浮出预览、面板当场长高，而视图侧的矩形要等
    // 下一轮布局才重新上报，那几毫秒里松手就是一次落空，文件原地飞回去（实测复现）。
    // AppKit 交给我们的落点本来就是从窗口底边量的，两边都不再碰 `bounds.height`，
    // 这个竞态窗口就不存在了，也不必在改高度时作废任何东西。

    /// 面板当前的高度，由 `BarPanel` 在改几何时先一步报上来。
    private var panelHeight: CGFloat = 0

    /// 可接收文件的项：项 id -> 它离面板底边的位置
    private var dropZones: [String: CGRect] = [:]
    /// 右键命中区。与拖放区分开：每一格都能有菜单，拖放只认文件夹与废纸篓。
    private var menuZones: [String: CGRect] = [:]
    /// 条自己的命中区，供「右键落在条的空白处」判定。
    private var barHitFrame: CGRect = .zero
    /// 正被拖拽悬停的项——不给高亮的话，用户不知道松手会掉进哪儿
    @Published private(set) var fileDropTarget: String?

    func setPanelHeight(_ height: CGFloat) {
        panelHeight = height
    }

    /// 左上原点的根坐标 → 离底边的距离。
    private func anchored(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: panelHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }

    func setDropZone(_ id: String, _ rect: CGRect?) {
        dropZones[id] = rect.map(anchored)
    }

    func dropZone(at point: CGPoint) -> String? {
        dropZones.first { $0.value.contains(point) }?.key
    }

    /// 落空时把登记在册的接收区一并记下来。只记落点说不出问题出在哪一侧——
    /// 是指针没落进去，还是这一格根本没登记上。
    var dropZoneReport: String {
        guard !dropZones.isEmpty else { return "一个都没登记" }
        return dropZones.sorted { $0.key < $1.key }.map { id, rect in
            String(format: "%@ x %.0f–%.0f y %.0f–%.0f",
                   id, rect.minX, rect.maxX, rect.minY, rect.maxY)
        }.joined(separator: "  ")
    }

    func setMenuZone(_ id: String, _ rect: CGRect?) {
        menuZones[id] = rect.map(anchored)
    }

    func menuZone(at point: CGPoint) -> String? {
        menuZones.first { $0.value.contains(point) }?.key
    }

    func barContains(_ point: CGPoint) -> Bool {
        barHitFrame.contains(point)
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
