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

    // MARK: 键盘切换（计划书 §6 M6）
    //
    // 选中态归模型，不归视图：选中的窗口在哪块屏由窗口自己决定，切换会话却是全局一份，
    // 视图各画各的。

    /// 键盘切换当前选中的窗口。不在本屏的窗口留给拥有它的那条 bar 去画。
    @Published private(set) var keySelection: CGWindowID?
    /// 选中的窗口收在哪个浮层里。视图据此把浮层打开——选中一个看不见的格子没有意义。
    @Published private(set) var keyPanel: FloatPanel?
    /// 切换会话进行中。选中状态从第一次按 Tab 起就成立——确认要靠它。
    private(set) var keySession = false
    /// 会话已经显形。视觉上的一切都归它管：选中底色、名牌、压暗、条的现身、浮层的展开。
    ///
    /// 与会话本身分开，是因为最高频的用法是飞快按一下 ⌥Tab 就松手换到上一个窗口。
    /// 那个动作全程不该有任何东西闪一下——系统的 ⌘Tab 同样如此。
    @Published private(set) var keyVisible = false

    /// 这条 bar 上的窗口，按格子从左到右。簇成员与收拢的标签页都按它们在条上的次序展开。
    /// 读的是 `barItems` 而不是 `layout()`：后者带渲染帧状态（溢出迟滞、飞回动画），
    /// 在渲染之外调用会把那些状态搅乱。
    var windowSequence: [CGWindowID] {
        barItems.flatMap { item -> [CGWindowID] in
            switch item {
            case .window(let cell):
                return [cell.id] + cell.tabs.map(\.id).filter { $0 != cell.id }
            case .cluster(let cluster):
                return cluster.windows.map(\.id)
            default:
                return []
            }
        }
    }

    /// 这条 bar 钉在哪块屏上。
    var screen: NSScreen? { NSScreen.screens.first { displayID($0) == display } }

    /// 这条 bar 所在屏幕的左边界，用来把多块屏从左到右接起来。
    var screenOriginX: CGFloat? { screen?.frame.minX }

    // MARK: 大预览（计划书 §6 M6）

    /// 此刻预览卡上是哪个窗口。nil = 没有卡，也就没得放大。
    /// 由视图报上来，`KeyboardSwitch` 据此决定那一下空格该不该吞。
    private(set) var peekTarget: CGWindowID?
    /// 大预览正开着。视图据此把卡片长到大档，面板据此把地方腾出来。
    @Published private(set) var peeking = false
    /// 大预览要的地方比浮层那一档大得多，单独一条通道。见 `BarPanel`。
    var onPeekRoom: ((Bool) -> Void)?

    private var peekRelease: DispatchWorkItem?
    /// 收回等一下：卡片缩回小档是一段约 0.28s 的弹簧，面板先落回来会把它拦腰裁掉。
    private static let peekReleaseDelay: TimeInterval = 0.36

    func setPeekTarget(_ id: CGWindowID?) {
        peekTarget = id
    }

    func setPeeking(_ value: Bool) {
        guard peeking != value else { return }
        peeking = value
        peekRelease?.cancel()
        peekRelease = nil
        guard !value else {
            onPeekRoom?(true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            peekRelease = nil
            onPeekRoom?(false)
        }
        peekRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekReleaseDelay, execute: work)
    }

    func setKeySelection(_ id: CGWindowID?) {
        keySelection = id
        // 没显形就不开浮层。快按快松那一下不该把簇的扇面弹出来又收回去。
        keyPanel = keyVisible ? id.flatMap(container) : nil
    }

    func setKeySession(_ active: Bool) {
        guard keySession != active else { return }
        if active {
            keySession = true
        } else {
            // 先撤选中再落幕。反过来的话视图那边看到的是「没有选中项、也没有会话」，
            // 分不出该收的是键盘开的浮层还是用户正悬停着的那个。
            setKeySelection(nil)
            keySession = false
            setKeyVisible(false)
        }
    }

    /// 会话显形 / 落幕。条的现身也归它——自动隐藏的条不该为一次快按快松冒出来一下。
    func setKeyVisible(_ value: Bool) {
        guard keyVisible != value else { return }
        keyVisible = value
        if value {
            // 触底唤出的停留判定要作废：条已经被键盘请出来了，那次计时回来只会把它收回去
            dwell?.cancel()
            dwell = nil
            hidden = false
            sampleBackdrop()
        } else {
            hidden = shouldHide
        }
        // 显形这一刻才轮到浮层：选中项可能早就落在溢出区里了，只在选中变化时算
        // 会漏掉「选好了才显形」这条路径。
        keyPanel = keyVisible ? keySelection.flatMap(container) : nil
    }

    /// 选中的窗口此刻收在哪个浮层里。三处收纳互斥，按它们在条上的优先次序判。
    private func container(of id: CGWindowID) -> FloatPanel? {
        // 选中的窗口不在本条上就与本条无关。标签组的成员关系来自索引、是全局的，
        // 不先挡这一道，别的屏也会为一个自己没有的窗口打开标签页面板。
        guard windowSequence.contains(id) else { return nil }
        if overflowed.contains(id) { return .overflow }
        // 标签组是否收拢由上一次布局决定；成员关系本身来自索引，不是布局的产物
        if foldedTabs, let window = world.windows.first(where: { $0.id == id }),
           case .tab(let host) = window.source {
            return .tabs(host)
        }
        for case .cluster(let cluster) in barItems
        where cluster.windows.contains(where: { $0.id == id }) {
            return .cluster(cluster.id)
        }
        return nil
    }

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
        // 宽度也算进 key：这行日志的用处正是「多宽的内容落到哪一档」，只按档位去重的话，
        // 宽度变了而档位没变就不重记，读到的那对宽度会停在第一帧，成为误导。
        let tier = "\(layout.metrics.icon)/\(layout.metrics.labelCap)/\(layout.overflow.count)"
            + (layout.foldsTabs ? "T" : "")
            + "/\(Int(availableWidth))/\(Int(layout.barWidth))"
        if tier != loggedTier {
            loggedTier = tier
            Timeline.log(String(format: "降级  屏 %@  可用 %.0f  内容 %.0f  图标 %.1f  标题上限 %.0f  溢出 %d  标签%@",
                                display.map(String.init) ?? "—",
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
    var clusterChoices: [(id: Int, name: String, color: ClusterColor)] {
        barItems.compactMap {
            guard case .cluster(let cluster) = $0 else { return nil }
            return (cluster.id, cluster.heading, cluster.color)
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
        // 预判现在只落在目标那一块屏上（见 `World` 的接线），撤销也只该落在同一条。
        // 少了这道守卫，别的屏上正被触底唤出的条会被这句按回去。
        guard fullscreenPredictionPending else { return }
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
        // 切换会话期间条是被键盘请出来的，指针挪开不该把它收回去
        guard !keySession,
              shouldHide,
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

    /// 条上某一项在屏幕坐标（AppKit，左下原点）里的位置。
    ///
    /// 命中区存的就是「离面板底边多远」，而面板贴着本屏底边、占满整宽，所以这里只差
    /// 一个屏幕原点的平移。分屏的落点预览要从这一格长出来，需要它。
    func screenRect(of id: String) -> CGRect? {
        guard let rect = menuZones[id],
              let screen = NSScreen.screens.first(where: { displayID($0) == display })
        else { return nil }
        return CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.minY + rect.minY,
                      width: rect.width, height: rect.height)
    }

    func barContains(_ point: CGPoint) -> Bool {
        barHitFrame.contains(point)
    }

    func setFileDropTarget(_ id: String?) {
        guard fileDropTarget != id else { return }
        fileDropTarget = id
    }

    // MARK: 拖放停留唤前（计划书 §6 M6）
    //
    // 拖着文件停在某个窗口格上，那个窗口被带到前台，拖拽会话不断，用户直接丢进去。
    // 系统对程序坞图标本来就是这么做的（弹簧文件夹是同一套手势语言），区别只在粒度：
    // 系统给的是「哪个 App」，这里给的是「哪一个窗口」。

    /// 停多久算「停住了」。访达的弹簧文件夹约半秒，与之对齐。§9 的待调参项。
    private static let springDwell: TimeInterval = 0.5

    /// 拖拽此刻停在哪个窗口格上。浮层据此报出那个窗口的名字——不然用户不知道
    /// 再停一下会把谁叫到前面来。
    @Published private(set) var dragOverWindow: CGWindowID?
    private var springWork: DispatchWorkItem?
    /// 唤前之前谁在前台。文件没丢进去就还回去。
    private var springOrigin: CGWindowID?

    /// 拖拽经过。同一格上继续动不重新计时——那样的话手抖一下就永远等不到唤前。
    func dragMoved(to point: CGPoint) {
        let window = windowCell(at: point)
        guard window?.id != dragOverWindow else { return }
        dragOverWindow = window?.id
        springWork?.cancel()
        springWork = nil
        // 已经在前台的窗口没什么可唤的
        guard let window, window.id != world.frontWindow else { return }
        let work = DispatchWorkItem { [weak self] in self?.spring(window) }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springDwell, execute: work)
    }

    /// 指针离开了本条。多半是往那个窗口里去了——唤前就此作数，不再还原。
    func dragLeft() {
        springWork?.cancel()
        springWork = nil
        dragOverWindow = nil
        springOrigin = nil
    }

    /// 拖拽在条上结束：文件没进那个窗口，把前台还回去。
    func dragEnded() {
        springWork?.cancel()
        springWork = nil
        dragOverWindow = nil
        guard let origin = springOrigin else { return }
        springOrigin = nil
        guard let window = world.windows.first(where: { $0.id == origin }) else { return }
        world.recall(window)
    }

    private func spring(_ window: IndexedWindow) {
        springWork = nil
        // 一次拖拽里可能连着唤起好几个窗口，要还原的始终是最初那个
        if springOrigin == nil { springOrigin = world.frontWindow }
        Timeline.log("拖放停留唤前  wid \(window.id) \(window.appName) — \(window.title)")
        world.recall(window)
    }

    /// 落在哪一格上。读右键那份命中区——它每一格都登记，而拖放接收区只有能接文件的
    /// 那几项（固定文件夹、废纸篓）才有。
    private func windowCell(at point: CGPoint) -> IndexedWindow? {
        guard let id = menuZone(at: point) else { return nil }
        for case .window(let cell) in barItems where cell.identity == id { return cell.window }
        return nil
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
