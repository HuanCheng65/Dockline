import Carbon.HIToolbox
import DocklineCore
import SwiftUI

/// 画在玻璃上的手绘层要按外观换色。
///
/// 玻璃本身由系统自适应，但底色、描边、分隔线这些是我们自己画上去的，不会跟着变。
/// 原先一律用白色叠加——深色外观下成立，浅色外观下就是白底上再加白，
/// 整条糊成一片、层次全丢。深色加白、浅色加黑，是同一件事的两个方向；
/// 黑色叠加视觉上更重，浅色一侧因此用更小的不透明度。
///
/// 文字与图标另有语义色（`.primary` / `.secondary`），不走这里。
private func ink(_ scheme: ColorScheme, _ dark: Double, _ light: Double) -> Color {
    scheme == .dark ? .white.opacity(dark) : .black.opacity(light)
}

/// 计划书 §3.1 的视觉规格。配色与尺寸逐值取自设计定稿 `design/Unified.dc.html`。
///
/// 只有玻璃条本身调用 glassEffect。格子的底色是嵌在整条玻璃**内部**的普通填充，不是独立的
/// 玻璃岛——独立岛会把整条 bar 打碎成十几段。
struct BarContent: View {
    @ObservedObject var model: BarModel
    /// 世界侧的变化也要驱动重绘：角标、活动状态、启动弹跳、窗口索引都在那边，
    /// 只观察 `model` 的话它们变了这里不会重画。
    @ObservedObject var world: World
    /// 手绘层与文字的明暗跟条背后的背景走，不跟窗口外观走。玻璃自己不管这件事
    /// （只对 ≤64pt 的玻璃管，见 `DockGlass`），由 `BackdropSensor` 采出来。
    private var scheme: ColorScheme { model.backdropScheme }
    /// 悬停的那一项。底色只在这一格与前台那一格上出现（计划书 §3.1）。
    @State private var hoveredItem: String?

    init(model: BarModel) {
        self.model = model
        world = model.world
    }
    /// 指针停在哪个 App 的窗口上。同 App 的兄弟格子据此联动高亮——
    /// 窗口可以被拖散到条上任何位置，散落的兄弟只能靠这个看见。
    @State private var hoveredApp: AppKey?
    /// 按下的那一项
    @State private var pressedItem: String?
    /// 按住多远才算开始拖。这个距离之内只是「按下」，松手即点击。
    fileprivate static let dragThreshold: CGFloat = 8
    /// 拖拽重排的进行态。单位是窗口格 / 无窗口的 App / 整个簇，不是「某个 App 的一堆窗口」。
    @State private var dragging: DragUnit?
    @State private var dragOffset: CGFloat = 0
    @State private var dropBefore: DragUnit?
    /// 拖动分隔线调整尺寸时的起始值
    @State private var resizeAnchor: CGFloat?
    /// 各可拖动单位在条内的位置，供拖拽时判断落点
    @State private var unitFrames: [DragUnit: CGRect] = [:]
    /// 簇在根坐标系里的中心横坐标，供面板定位
    @State private var clusterAnchors: [Int: CGFloat] = [:]
    /// 拖拽中压住的那一个——松手即与它吸合成簇
    @State private var mergeTarget: DragUnit?
    /// 分屏（计划书 §3「接管最大化」）。把格子提出条的上沿就上膛，此后指针在屏幕的
    /// 哪一半，落点就是哪一半；落点由屏幕上那块玻璃报，条上只留一个压暗的占位。
    @State private var splitSpot: Maximizer.Spot?
    /// 落点是从这一格长出来的，取消时也缩回这里。屏幕坐标。
    @State private var splitOrigin: CGRect?
    /// 落点在哪块屏上——指针所在的那块。松手时要拿它去摆位，不能让摆位那边再推一次。
    @State private var splitScreen: NSScreen?
    /// 本次拖拽能不能分屏。起拖那一刻定一次，拖拽期间不会变。
    @State private var splitable = false
    /// 本次拖拽已被 Esc 取消。手势没法从外面掐断，只能记下来、松手时什么都不做。
    @State private var splitCancelled = false
    @State private var escapeWatch: Any?
    /// 指针高出条的上沿多少算上膛。重排是横向的手势，横着晃到不了这个高度。
    private static let splitArm: CGFloat = 24
    /// 掉回多低算解除。与上膛留出迟滞，免得在临界线上抖。
    private static let splitDisarm: CGFloat = 8
    /// 换边的迟滞。指针在中线附近微动时，落点不该来回翻。
    private static let splitEdge: CGFloat = 24
    /// 悬停浮出面板的那个簇，与它在根坐标系里的中心横坐标
    @State private var panel: (kind: FloatPanel, anchorX: CGFloat)?
    @State private var panelShow: DispatchWorkItem?
    @State private var panelHide: DispatchWorkItem?
    /// 从面板里往外拖的窗口
    @State private var overflowAnchor: CGFloat = 0
    /// 浮层的上一档，用来撑过「旧的没了、新的还没到」那一帧。见 `body`。
    @State private var lingering: FloatStage?
    @State private var lingerWork: DispatchWorkItem?
    /// 键盘选中那块底色在格与格之间滑动所需的命名空间
    @Namespace private var keyFocus
    /// 当前这个浮层是键盘切换开的，不是悬停开的。收的时候要认这一点：
    /// 不能因为键盘那边没有选中项了，就把用户正悬停着的浮层一并收掉。
    @State private var panelFromKeyboard = false
    @State private var cellAnchors: [String: CGFloat] = [:]
    @State private var panelDragging: CGWindowID?
    @State private var panelDragOffset: CGSize = .zero
    /// 计划书 §3：悬停浮出，与预览同一个节奏
    private static let panelDwell: TimeInterval = 0.22

    private static let barSpace = "moor.bar"
    /// 浮层也要按这个坐标系报位置（见 `WindowPanel`），因此不是 private
    static let rootSpace = "moor.root"

    @StateObject private var thumbnails = Thumbnails()
    /// 指针停在某个窗口格上超过 dwell 后要预览的目标
    @State private var preview: PreviewTarget?
    @State private var previewDwell: DispatchWorkItem?
    /// 当前指针所在的窗口格。相邻格子的「进入」与「离开」事件顺序并不保证，
    /// 靠它判断一条「离开」是否真的属于当前这一格。
    @State private var hoveredCell: CGWindowID?
    /// 计划书 §3：悬停约 260ms 后浮出
    private static let previewDwell: TimeInterval = 0.26

    struct PreviewTarget: Equatable {
        let window: IndexedWindow
        let appName: String
        /// 格子中心在根坐标系里的横坐标
        let anchorX: CGFloat
    }

    var body: some View {
        let layout = model.layout()
        // 收场留一拍：指针从一格挪到另一格时，先来「离开旧格」再来「进入新格」，
        // 夹在中间那一帧两头都不成立。照那一帧办事，浮层会被整个撤掉再重新长出来，
        // 看起来就是闪一下。`lingering` 让它把这一帧撑过去。
        let live = floatStage(layout)
        let stage = live ?? lingering
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // 面板占满屏幕底部整条；全透明像素不参与命中测试，点击直接穿透到下方窗口
                Color.clear
                glassBar(layout)
                    .padding(.bottom, BarMetrics.bottomGap)
                    .offset(y: model.hidden ? BarMetrics.barHeight + BarMetrics.bottomGap + 6 : 0)
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.hidden)
                    .animation(.spring(response: 0.30, dampingFraction: 0.82), value: layout.barWidth)
                if let stage {
                    let size = floatSize(stage, in: geometry.size, layout: layout)
                    floatContent(stage, in: layout, available: geometry.size.width)
                        // 底边对齐：浮层贴着条的上沿往上长，长大缩小时下面这条边不动，
                        // 名字那一行因此原地不动，缩略图从它上方展开。
                        .frame(width: size.width, height: size.height, alignment: .bottom)
                        .environment(\.colorScheme, model.floatScheme)
                        .background {
                            DockGlass(cornerRadius: BarMetrics.barRadius).allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: BarMetrics.barRadius,
                                                    style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: BarMetrics.barRadius,
                                                       style: .continuous))
                        // 只有一排窗口那一档是可操作的，另外两档纯是说明
                        .allowsHitTesting(stage.isList)
                        // 量尺寸与悬停判定都必须挂在 .position 之前。`.position` 交回来的是
                        // 一个铺满可用空间的容器，挂在它后面，量到的是整块根视图、
                        // 悬停判定也变成整块根视图（面板因此收不回去，采样也采到半屏）。
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.rootSpace)) }
                            action: { model.setFloatFrame($0) }
                        .onHover { $0 ? keepPanel() : dismissPanel() }
                        .onDisappear { model.setFloatFrame(nil) }
                        // 从那一格的位置长出来，收回时缩回同一个点
                        .transition(.scale(scale: 0.28,
                                           anchor: panelAnchor(stage.anchorX, in: geometry.size))
                            .combined(with: .opacity))
                        .position(x: floatingX(stage.anchorX, in: geometry.size.width,
                                               half: size.width / 2),
                                  y: geometry.size.height - BarMetrics.bottomGap
                                      - BarMetrics.barHeight - Self.floatGap - size.height / 2)
                        // 动效挂在浮层自己身上，不挂在整棵树上：挂在外面的话，
                        // 悬停与键盘在同一次事务里都变了时，两条 .animation 会互相打架。
                        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: stage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 调度中心期间整条让位：不滑走而是淡出——MC 自己就是一段位移动画，
            // 再叠一段位移只会打架，而且淡出比滑出快，让得出去才是重点。
            .opacity(model.yielding ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: model.yielding)
            .coordinateSpace(name: Self.rootSpace)
            // 条以上那块空间由面板按需长出来（见 BarPanel）。悬停也算——浮出前的
            // 那两百多毫秒里就得把地方准备好，等浮层出现再长就晚了。
            // 键盘会话也要算进来：名牌与预览卡浮在条上方，面板不先长上去它们会被裁掉
            .onChange(of: hoveredItem != nil || panel != nil || preview != nil
                          || dragging != nil || model.keyVisible) { _, needed in
                model.needsFloatRoom(needed)
            }
            // 键盘选中的窗口收在簇、标签组或溢出区里时，把收着它的浮层打开——
            // 选中一个看不见的格子没有意义。走的是悬停那一套 `panel` 状态，
            // 不另起一层：同一时刻只该有一个浮层。
            .onChange(of: model.keyPanel) { _, kind in
                panelShow?.cancel()
                panelShow = nil
                keepPanel()
                guard let kind, let anchorX = keyAnchor(kind, in: layout) else {
                    guard panelFromKeyboard else { return }
                    panelFromKeyboard = false
                    panel = nil
                    return
                }
                panelFromKeyboard = true
                panel = (kind: kind, anchorX: anchorX)
            }
            // 停在一格上犹豫，就把带缩略图的预览卡长出来——键盘与指针最终落到同一处。
            // 一路划过去时不截图：那会把按需的缩略图变成常驻采样（§2）。
            // 选中不动、只是刚显形也算一次「停稳」，所以两个来源都要听。
            .onChange(of: live) { _, current in
                lingerWork?.cancel()
                lingerWork = nil
                guard current == nil else { lingering = current; return }
                let work = DispatchWorkItem { lingering = nil }
                lingerWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerGrace, execute: work)
            }
            .onChange(of: model.keySelection) { _, _ in syncKeyPreview(layout) }
            .onChange(of: model.keyVisible) { _, _ in syncKeyPreview(layout) }
            // 名牌与选中底色换一格都是滑过去，不是这边灭那边亮——
            // 一块东西在移动读起来是连续的，十块各自明灭读起来是抽搐
            .animation(.spring(response: 0.26, dampingFraction: 0.88), value: model.keySelection)
            .animation(.easeOut(duration: 0.14), value: model.keyVisible)
            .animation(.easeOut(duration: 0.16), value: preview)
            // 悬停开的浮层带弹性，因为指针可能只是路过，那点回弹是「它在犹豫」；
            // 键盘是明确意图，即开即合，一路 Tab 过去才不会看成抽搐。
            .animation(panelFromKeyboard ? .easeOut(duration: 0.12)
                                         : .spring(response: 0.30, dampingFraction: 0.78),
                       value: panel?.kind)
        }
    }

    /// 键盘要打开的浮层该从哪一格长出来。量到的锚点还没到（格子刚出现）时返回 nil，
    /// 那一轮就不开浮层——条上那一格的选中环仍然指得出位置。
    private func keyAnchor(_ kind: FloatPanel, in layout: BarLayout) -> CGFloat? {
        switch kind {
        case .cluster(let id):
            return clusterAnchors[id]
        case .overflow:
            return overflowAnchor
        case .tabs(let host):
            for item in layout.items {
                guard case .window(let cell) = item, cell.id == host else { continue }
                return cellAnchors[item.id]
            }
            return nil
        }
    }

    /// 面板生长的锚点：簇那一格的中心落在面板宽度上的哪个比例位置
    /// 缩放锚点**按外层容器解析，不是按面板自己**——`.position` 交回来的容器铺满整块根视图，
    /// 把 `.transition` 挂到 `.position` 之前也一样（实测：一块 200×100 的视图定位在
    /// x=300、锚点写成面板内的 (0.5, 1)，它仍然朝 1200 宽容器的底部中央收拢）。
    /// 所以这里给的是根视图里的比例：横向对准那一格，纵向对准条的中线。
    private func panelAnchor(_ anchorX: CGFloat, in size: CGSize) -> UnitPoint {
        UnitPoint(x: anchorX / max(size.width, 1),
                  y: (size.height - BarMetrics.bottomGap - BarMetrics.barHeight / 2)
                      / max(size.height, 1))
    }

    /// 浮层贴着格子居中，但不许越出屏幕边缘
    private func floatingX(_ anchor: CGFloat, in width: CGFloat, half: CGFloat) -> CGFloat {
        min(max(anchor, half + 12), width - half - 12)
    }

    // MARK: 簇的面板
    //
    // 面板浮在条的上方，而不是原地把条撑开：原地展开会把右边的项全推走，
    // 而且收拢态一旦在悬停时消失，「单击整组前置」就没有可点的目标了。

    private func cluster(_ id: Int, in layout: BarLayout) -> BarCluster? {
        for case .cluster(let cluster) in layout.items where cluster.id == id { return cluster }
        return nil
    }

    private func schedulePanel(_ kind: FloatPanel, anchorX: CGFloat) {
        keepPanel()
        guard panel?.kind != kind else { return }
        panelShow?.cancel()
        let work = DispatchWorkItem { panel = (kind: kind, anchorX: anchorX) }
        panelShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelDwell, execute: work)
    }

    /// 溢出区按点击开——它是控件，不是悬停浮出的预览。
    private func toggleOverflow(anchorX: CGFloat) {
        keepPanel()
        panelShow?.cancel()
        panelShow = nil
        panel = panel?.kind == .overflow ? nil : (kind: .overflow, anchorX: anchorX)
    }

    /// 面板里要显示什么。
    private func panelContent(_ kind: FloatPanel, in layout: BarLayout)
        -> (windows: [BarWindow], heading: String, subheading: String, color: ClusterColor?)? {
        switch kind {
        case .cluster(let id):
            guard let cluster = cluster(id, in: layout) else { return nil }
            return (cluster.windows, cluster.heading, cluster.subheading, cluster.color)
        case .tabs(let host):
            for case .window(let cell) in layout.items
            where cell.id == host && !cell.tabs.isEmpty {
                return (cell.tabs, cell.appName, "\(cell.tabs.count) 个标签页", nil)
            }
            return nil
        case .overflow:
            guard !layout.overflow.isEmpty else { return nil }
            return (layout.overflow, "更多窗口", "\(layout.overflow.count) 个窗口", nil)
        }
    }

    /// 指针从收拢态挪到面板上要经过一段空隙，立刻收会让面板根本够不着。
    private func dismissPanel() {
        panelShow?.cancel()
        panelShow = nil
        guard panelDragging == nil else { return }
        panelHide?.cancel()
        let work = DispatchWorkItem { panel = nil }
        panelHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func keepPanel() {
        panelHide?.cancel()
        panelHide = nil
    }

    // MARK: 悬停预览

    private func schedulePreview(_ target: PreviewTarget?, from id: CGWindowID) {
        guard let target else {
            guard hoveredCell == id else { return }
            hoveredCell = nil
            previewDwell?.cancel()
            previewDwell = nil
            preview = nil
            return
        }
        hoveredCell = id
        previewDwell?.cancel()
        let work = DispatchWorkItem {
            preview = target
            thumbnails.capture(target.window.id)
        }
        previewDwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDwell, execute: work)
    }

    @ViewBuilder
    private func glassBar(_ layout: BarLayout) -> some View {
        // 宽度交给 SwiftUI 自己量，不按 BarLayout 算出来的数值硬设。
        // 原因是实测出来的：NSFont 量出的字宽比 SwiftUI 实际排版需要的少几个点，
        // 硬设宽度会让柔性的 Text 被挤掉（「Dockline」被截成「M…」）。
        // BarLayout 的宽度只用来选降级档位——那个判断差几个点无所谓。
        row(layout)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: BarMetrics.barHeight)
        .environment(\.colorScheme, scheme)
        .background { DockGlass(cornerRadius: BarMetrics.barRadius).allowsHitTesting(false) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.rootSpace)) }
            action: { model.setBarFrame($0) }
        // 背板不参与命中测试，条的空白处要自己给出可右键的形状
        .contentShape(RoundedRectangle(cornerRadius: BarMetrics.barRadius, style: .continuous))
    }

    private func row(_ layout: BarLayout) -> some View {
        HStack(spacing: 0) {
            ForEach(layout.items) { item in
                reorderable(item, in: layout) {
                    itemView(item, metrics: layout.metrics)
                        .overlay {
                            if model.fileDropTarget == item.id {
                                RoundedRectangle(cornerRadius: layout.metrics.cellRadius,
                                                 style: .continuous)
                                    .strokeBorder(ink(scheme, 0.55, 0.42), lineWidth: 2)
                                    .padding(BarMetrics.backingInset)
                            }
                        }
                        // 键盘选中的那一块底色。只声明在选中的那一格上，靠
                        // matchedGeometryEffect 在格与格之间滑过去——十块各自明灭
                        // 读起来是抽搐，一块东西在移动读起来才是连续的。
                        .background {
                            if model.keyVisible, keySelected(item) {
                                BackingFill(backing: .focused,
                                            shape: RoundedRectangle(
                                                cornerRadius: layout.metrics.cellRadius,
                                                style: .continuous))
                                    .matchedGeometryEffect(id: "key.focus", in: keyFocus)
                            }
                        }
                        // 会话期间其余项压暗，让选中项自己站出来。
                        // 最小化的格子本来就是 0.42，两者相乘会更淡——那正是它该有的次序。
                        .opacity(model.keyVisible && !keySelected(item) ? 0.38 : 1)
                }
                // 被拎起来的那一格的层级只在自己这一段里有效，整段不抬起来的话，
                // 它会从邻段的底色下面穿过去。
                .zIndex(lifts(item) ? 2 : 0)
                // 插入 / 移除都是原地生长与收拢，不是凭空出现和消失。
                // 邻居的让位由 HStack 自己的位移过渡承担。
                .transition(flight(item, overflowing: !layout.overflow.isEmpty))
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rootSpace)).midX }
                    action: { cellAnchors[item.id] = $0 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.rootSpace)) }
                    action: { model.setMenuZone(item.id, $0) }
                .onDisappear { model.setMenuZone(item.id, nil) }
            }
        }
        .padding(.horizontal, BarMetrics.barPaddingH)
        .coordinateSpace(name: Self.barSpace)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: layout.signature)
    }

    // MARK: 拖拽重排
    //
    // 计划书 §2「顺序稳定性高于新近度」：顺序由用户掌握，程序绝不自动重排。
    // 只有窗口区的槽位参与——启动台、分隔线、固定文件夹、垃圾桶位置固定。
    //
    // 格子用的是 onTapGesture 而不是 Button：Button 会先把手势吃掉，
    // 结果要么拖不动，要么拖完松手还顺带触发一次召回。

    @ViewBuilder
    private func reorderable(_ item: BarItem, in layout: BarLayout,
                             @ViewBuilder content: () -> some View) -> some View {
        if let unit = item.dragUnit {
            content().dragged(as: unit, metrics: layout.metrics, drag: barDrag)
        } else {
            content()
        }
    }

    /// 条上的拖拽。窗口格在 RunItem 里，拿不到这里的状态，所以打包成一组闭包传下去。
    private var barDrag: DragBinding {
        DragBinding(
            record: { unit, rect in
                // 拖拽中不再更新位置记录：被拖的那个已经带了 offset，
                // 用它当落点判据会自己追自己。
                if dragging == nil { unitFrames[unit] = rect }
            },
            offset: { unit in
                // 分屏态下这一格回到原位：它已经交给屏幕上那块落点了，再跟着指针走
                // 就成了两个东西在表示同一件事。
                if unit == dragging {
                    return splitSpot == nil ? CGSize(width: dragOffset, height: 0) : .zero
                }
                return CGSize(width: displacement(of: unit), height: 0)
            },
            lifted: { $0 == dragging && splitSpot == nil },
            merging: { $0 == mergeTarget },
            placing: { $0 == dragging && splitSpot != nil },
            changed: { unit, translation in
                guard !splitCancelled else { return }
                // 手势的最小距离是 0，为的是拿到「按下」；没走出 dragThreshold
                // 就还不是拖拽。不能再挂第二个手势去拿按下态——两个手势会互相抢，
                // 内层那个会把负责重排的这条整个吃掉。
                guard max(abs(translation.width), abs(translation.height))
                        >= Self.dragThreshold else {
                    pressedItem = unit.backingID
                    return
                }
                pressedItem = nil
                if dragging != unit {
                    dragging = unit
                    // 这一格在屏幕上的位置只量这一次：拖拽期间它不会挪，而分屏一旦上膛
                    // 就要从这儿长出来。能不能分屏也在这里定一次——判据每一帧都一样，
                    // 而它不成立时要说的话只该说一遍。
                    splitOrigin = cellRect(of: unit)
                    splitable = canSplit(unit)
                }
                dragOffset = translation.width
                // 提出条的上沿即转入分屏。此时既不重排也不捏合——落点在屏幕上，
                // 条上的次序一个字都没改。
                guard !aimSplit(unit) else {
                    mergeTarget = nil
                    dropBefore = nil
                    return
                }
                // 压在另一个正中 = 捏合；压在缝里 = 重排。
                // 判定按被拖那个的视觉中心，不按指针——抓在格子的哪一端，指针就偏多少。
                let center = (unitFrames[unit]?.midX ?? 0) + translation.width
                mergeTarget = canMerge(unit) ? mergeCandidate(at: center, moving: unit) : nil
                dropBefore = mergeTarget == nil ? dropTarget(at: center, moving: unit) : nil
            },
            ended: { unit in
                pressedItem = nil
                let spot = splitSpot
                let screen = splitScreen
                let cancelled = splitCancelled
                splitSpot = nil
                splitOrigin = nil
                splitScreen = nil
                splitable = false
                splitCancelled = false
                watchEscape(false)
                // 只是按了一下、没拖动：什么都不做。落点是 nil 意味着「拖到末尾」，
                // 在这里执行就成了「点一下就把它挪到最后」。
                guard dragging != nil else { return }
                if cancelled {
                    // Esc 已经把状态收干净了，这里只负责别再做事
                } else if let spot, let screen {
                    tile(unit, at: spot, on: screen)
                } else if let mergeTarget {
                    model.world.formCluster(unit, into: mergeTarget)
                } else {
                    model.world.move(unit, before: dropBefore)
                }
                dragging = nil
                dragOffset = 0
                dropBefore = nil
                mergeTarget = nil
            })
    }

    // MARK: 分屏
    //
    // 计划书 §3「接管最大化」：拖的是格子而非窗口本体，与系统拼贴的手势不冲突。
    // 它做得到系统做不到的事——压在别人底下、已经最小化的窗口，一个手势就贴过去，
    // 不必先把它翻出来。

    /// 这一次拖拽能不能分屏。
    private func canSplit(_ unit: DragUnit) -> Bool {
        // 簇与没有窗口的槽位不参与：一个簇往哪半边贴是歧义的。
        guard case .window(let id) = unit,
              let window = world.windows.first(where: { $0.id == id }) else { return false }
        guard splitOrigin != nil else {
            // 正在被拖的格子一定在条上，量不到它只可能是几何上报断了。
            Timeline.log("⚠️ 分屏取不到 wid \(id) 那一格在屏幕上的位置，本次拖拽不能分屏")
            return false
        }
        // 摆位要写窗口的几何，写几何要有 AX 引用，而别的 Space 上的窗口没有引用。
        // 这时要么先把它迁过来（计划书 §5 第 1.5 层），要么干脆不上膛——宁可提上去
        // 没有反应，也不要把用户甩到另一个桌面去、还什么都没摆成。
        guard window.element != nil || SpaceMove.available else {
            Timeline.log("分屏不可用 wid \(id) \(window.appName)：窗口在其他 Space，"
                         + "而迁移能力不可用（缺 \(SpaceMove.missing.joined(separator: ", "))）")
            return false
        }
        return true
    }

    /// 更新落点，返回是否处于分屏态。
    private func aimSplit(_ unit: DragUnit) -> Bool {
        guard splitable, case .window(let id) = unit,
              let window = world.windows.first(where: { $0.id == id }),
              let origin = splitOrigin else { return false }
        let pointer = NSEvent.mouseLocation
        // 目标屏是指针所在的那一块，不是格子来自的那一块——手已经过去了。
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main else { return false }
        // 判据是指针离条的上沿多高，不是手势拖了多远：抓在格子的哪个位置、条有多高
        // 都不该影响「提出去了没有」这件事。
        let lift = pointer.y - (screen.frame.minY + BarMetrics.reservedBottom)
        if splitSpot == nil {
            guard lift >= Self.splitArm else { return false }
            watchEscape(true)
        } else if lift < Self.splitDisarm {
            splitSpot = nil
            splitScreen = nil
            watchEscape(false)
            world.splitPreview.cancel()
            return false
        }
        let middle = screen.frame.midX
        let spot: Maximizer.Spot
        switch splitSpot {
        case .left where pointer.x < middle + Self.splitEdge: spot = .left
        case .right where pointer.x > middle - Self.splitEdge: spot = .right
        default: spot = pointer.x < middle ? .left : .right
        }
        splitSpot = spot
        // 落定要用的是**这块屏**，不是窗口现在所在的那块。两边各推一次的话，预览飞到了
        // 这块屏、窗口却贴回原来那块——实机撞到过。
        splitScreen = screen
        world.splitPreview.aim(at: world.maximizer.rect(spot, on: screen), on: screen,
                               from: origin,
                               icon: world.icon(pid: window.pid),
                               title: window.title.isEmpty ? window.appName : window.title)
        return true
    }

    private func tile(_ unit: DragUnit, at spot: Maximizer.Spot, on screen: NSScreen) {
        guard case .window(let id) = unit,
              let window = world.windows.first(where: { $0.id == id }) else { return }
        world.tile(window, at: spot, on: screen)
    }

    private func cellRect(of unit: DragUnit) -> CGRect? {
        guard let item = model.barItems.first(where: { $0.dragUnit == unit }) else { return nil }
        return model.screenRect(of: item.id)
    }

    /// 拖拽中按 Esc 放弃。原生的拖放也是这个键，没有理由另立一个。
    ///
    /// 只挂全局监听：本体是 nonactivating 面板，永远不会成为 key window，按键根本不到
    /// 我们这儿来。手势掐不断，所以取消是「把状态收干净、剩下的照走，松手时不做事」。
    private func watchEscape(_ on: Bool) {
        guard on != (escapeWatch != nil) else { return }
        guard on else {
            escapeWatch.map(NSEvent.removeMonitor)
            escapeWatch = nil
            return
        }
        escapeWatch = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard Int(event.keyCode) == kVK_Escape else { return }
            splitCancelled = true
            splitSpot = nil
            splitOrigin = nil
            splitScreen = nil
            dragging = nil
            dragOffset = 0
            dropBefore = nil
            mergeTarget = nil
            watchEscape(false)
            world.splitPreview.cancel()
        }
    }

    /// 面板里的拖拽。往外拖就是出组，落点不重要——窗口会回到簇的紧后面，
    /// 位置可预期，比在浮层与条之间换算坐标可靠。
    private var panelDrag: DragBinding {
        DragBinding(
            record: { _, _ in },
            offset: { unit in
                guard case .window(let id) = unit, panelDragging == id else { return .zero }
                return panelDragOffset
            },
            lifted: { unit in
                guard case .window(let id) = unit else { return false }
                return panelDragging == id
            },
            merging: { _ in false },
            placing: { _ in false },
            changed: { unit, translation in
                guard case .window(let id) = unit else { return }
                guard max(abs(translation.width), abs(translation.height))
                        >= Self.dragThreshold else { return }
                panelDragging = id
                panelDragOffset = translation
            },
            ended: { unit in
                guard case .window(let id) = unit, panelDragging == id else { return }
                model.world.detachFromCluster(id)
                panelDragging = nil
                panelDragOffset = .zero
                dismissPanel()
            })
    }

    private func lifts(_ item: BarItem) -> Bool {
        item.dragUnit != nil && item.dragUnit == dragging
    }

    /// 条上从左到右的全部可拖动单位
    private var dragUnits: [DragUnit] {
        model.barItems.compactMap(\.dragUnit)
    }

    /// 能参与捏合的只有窗口与簇。没有窗口的 App 对「整组前置」没有贡献，
    /// 放进组里只会让整组的动作变成「顺便启动它」。
    private func canMerge(_ unit: DragUnit) -> Bool {
        if case .app = unit { return false }
        return true
    }

    /// 拖拽中其余项的让位量。被拖的那个跟着手指走，它原来占的位置由后面的补上，
    /// 落点处则空出一格——不给这个反馈的话，用户松手前不知道会掉在哪。
    private func displacement(of unit: DragUnit) -> CGFloat {
        // 判定为捏合时谁都不让位：让位是「要插到这儿」的反馈，与捏合无关。
        // 分屏同理，而且更要紧：那一格根本没离开条上的位置。
        guard mergeTarget == nil, splitSpot == nil else { return 0 }
        guard let moving = dragging, moving != unit,
              let width = unitFrames[moving]?.width else { return 0 }
        let units = dragUnits
        guard let from = units.firstIndex(of: moving),
              let index = units.firstIndex(of: unit) else { return 0 }
        let to: Int
        if let dropBefore, let target = units.firstIndex(of: dropBefore) {
            to = target > from ? target - 1 : target
        } else {
            to = units.count - 1
        }
        let step = width
        if from < to, index > from, index <= to { return -step }
        if to < from, index >= to, index < from { return step }
        return 0
    }

    /// 压住某一个的正中 60% = 捏合。落在两项之间的缝里才是重排。
    private func mergeCandidate(at x: CGFloat, moving unit: DragUnit) -> DragUnit? {
        for candidate in dragUnits {
            guard candidate != unit, canMerge(candidate),
                  let frame = unitFrames[candidate] else { continue }
            let band = frame.insetBy(dx: frame.width * 0.2, dy: 0)
            if x >= band.minX && x <= band.maxX { return candidate }
        }
        return nil
    }

    /// 落点：第一个中线在指针右侧的那一个。都在左侧则落到末尾。
    private func dropTarget(at x: CGFloat, moving unit: DragUnit) -> DragUnit? {
        for candidate in dragUnits {
            guard candidate != unit, let frame = unitFrames[candidate] else { continue }
            if x < frame.midX { return candidate }
        }
        return nil
    }

    /// 格子的进出。条上有溢出入口时，出去的格子朝它飞过去、从溢出区回来的格子从它那儿飞出来——
    /// 「我那一格去哪了」必须看得见。其余情况仍是原地生长与收拢。
    ///
    /// 飞出去这一侧是近似：视图被移除时用的是它最后一次渲染时带上的过渡，那时还不知道
    /// 自己是被收进溢出区还是窗口关掉了。条上有溢出入口时一律朝它飞——窗口正好在此时关掉的话，
    /// 方向仍是「离开条」，读起来不算错。飞回来这一侧是精确的：模型知道谁刚从溢出区出来。
    private func flight(_ item: BarItem, overflowing: Bool) -> AnyTransition {
        let plain = AnyTransition.scale(scale: 0.55, anchor: .bottom).combined(with: .opacity)
        var insertion = plain
        var removal = plain
        if overflowing, let mine = cellAnchors[item.id] {
            let fly = AnyTransition.modifier(
                active: Flight(dx: overflowAnchor - mine, gone: true),
                identity: Flight(dx: 0, gone: false))
            removal = fly
            if case .window(let cell) = item, model.justReturned.contains(cell.id) { insertion = fly }
        }
        // 从别的屏迁过来的格子，从那块屏的方向飞进来。走的这一侧同样是近似，而且比溢出
        // 那一侧更彻底：格子被移除时用的是它最后一次渲染时带上的过渡，那时它还在本屏，
        // 无从知道自己要去哪块屏。到达这一侧是精确的，方向也由它承担。
        if case .window(let cell) = item, let source = model.justArrived[cell.id] {
            insertion = .modifier(active: Flight(dx: arrivalOffset(from: source), gone: true),
                                  identity: Flight(dx: 0, gone: false))
        }
        return .asymmetric(insertion: insertion, removal: removal)
    }

    /// 跨屏到达时格子飞过的距离。只要读得出「从那一侧来的」，不必按真实屏距换算。
    private static let arrivalTravel: CGFloat = 220

    /// 源屏在左就从左边进，在右就从右边进。上下叠放的两块屏中心横坐标相同，
    /// 统一从左侧进——那种排布下左右本来就没有意义，有个一致的来向即可。
    private func arrivalOffset(from source: CGDirectDisplayID) -> CGFloat {
        guard let from = NSScreen.screens.first(where: { displayID($0) == source }),
              let here = NSScreen.screens.first(where: { displayID($0) == model.display })
        else { return -Self.arrivalTravel }
        return from.frame.midX <= here.frame.midX ? -Self.arrivalTravel : Self.arrivalTravel
    }

    @ViewBuilder
    private func itemView(_ item: BarItem, metrics: BarMetrics) -> some View {
        switch item {
        case .launcher(let url):
            BareItem(icon: model.world.icon(app: url, bundleID: Bundle(url: url)?.bundleIdentifier),
                     metrics: metrics, backing: backing(item.id))
                .hoverTracked(item.id, $hoveredItem)
                .clickable(item.id, $pressedItem) { model.world.open(url) }
                .help(model.world.displayName(of: url))

        case .separator:
            // 计划书 §3.1：分隔线只隔「不是窗口的东西」，窗口之间一律不隔。
            // 它同时是尺寸调节手柄——系统程序坞也是拖分隔线改大小。
            LinearGradient(colors: [.clear, ink(scheme, 0.22, 0.16), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 1, height: BarMetrics.separatorHeight)
                .padding(.horizontal, BarMetrics.separatorMargin)
                .contentShape(Rectangle())
                .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizeAnchor == nil { resizeAnchor = model.world.iconSize }
                        let base = resizeAnchor ?? model.world.iconSize
                        model.world.iconSize = min(max(base - value.translation.height,
                                                 BarMetrics.minIcon), BarMetrics.maxIcon)
                    }
                    .onEnded { _ in
                        resizeAnchor = nil
                        model.world.commitIconSize()
                    })

        case .notice(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, metrics.cellInset)

        // 固定 App 的槽位与它的窗口格必须走**同一个分支**：switch 的每个分支在 SwiftUI 眼里
        // 是不同的结构，分支一换就是拆掉重建，挂在旧视图上的动画（启动弹跳）当场断掉。
        // 光让 BarItem.id 稳定不够——身份稳住的是「谁」，结构换掉的是「这一格还是不是原来那棵树」。
        case .window, .dormant:
            slotCell(item, metrics: metrics)

        case .overflow(let cells):
            OverflowEntry(count: cells.count, metrics: metrics, backing: backing(item.id))
                .hoverTracked(item.id, $hoveredItem)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rootSpace)).midX }
                    action: { overflowAnchor = $0 }
                .onTapGesture { toggleOverflow(anchorX: overflowAnchor) }
                .help("还有 \(cells.count) 个窗口")

        case .cluster(let cluster):
            FoldedCluster(cluster: cluster, icons: cluster.windows.map(model.world.icon(for:)),
                          metrics: metrics, backing: backing(item.id))
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rootSpace)).midX }
                    action: { center in
                        clusterAnchors[cluster.id] = center
                        if panel?.kind == .cluster(cluster.id) { panel?.anchorX = center }
                    }
                .hoverTracked(item.id, $hoveredItem)
                .onHover { hovering in
                    guard let center = clusterAnchors[cluster.id] else { return }
                    hovering ? schedulePanel(.cluster(cluster.id), anchorX: center)
                             : dismissPanel()
                }
                // 单击 = 整体开关。与单个窗口同一条规则，簇上没有例外。
                .onTapGesture { model.world.toggleCluster(cluster.id) }

        case .folder(let url):
            BareItem(icon: model.world.icon(file: url), metrics: metrics, backing: backing(item.id))
                .hoverTracked(item.id, $hoveredItem)
                .clickable(item.id, $pressedItem) { model.world.open(url) }
                .dropZone(item.id, model: model)
                .help(model.world.displayName(of: url))

        case .trash:
            BareItem(icon: NSImage(named: model.world.trashFull ? NSImage.trashFullName
                                                          : NSImage.trashEmptyName),
                     metrics: metrics, backing: backing(item.id))
                .hoverTracked(item.id, $hoveredItem)
                .clickable(item.id, $pressedItem) { model.world.open(model.world.trashURL) }
                .help(model.world.trashFull ? "废纸篓（非空）" : "废纸篓")
                .dropZone(item.id, model: model)
        }
    }

    /// 底色的取值。按下 > 悬停 > 联动，前台那一格自己是亮底，不被悬停顶掉。
    // MARK: 浮层
    //
    // 条上方只有一块浮层，三档形态是它的三种尺寸，不是三个控件：
    //   ① 名字（只报一格叫什么）→ ② 预览卡（加缩略图与 App 名）→ ③ 一排窗口（簇 / 标签组 / 溢出）
    // 因此它们共用一块玻璃、一个圆角、一条底边、一套进出动效。档与档之间是这块东西
    // 自己长大或缩小——三个控件之间只能互相淡入淡出，那是接不上的。
    //
    // 尺寸必须由这里算准、驱动到 `.frame` 上，不能交给排版去撑：交给排版的话，
    // 尺寸只在布局完成后才知道，动画拿不到起止值，也就没有过渡可言。

    /// 条与浮层之间那道缝。三档共用一个值——各留各的，换档时浮层会上下跳一下。
    private static let floatGap: CGFloat = 9
    /// 浮层收场前的宽限。只需要盖住事件之间那一两帧，不是让它赖着不走。
    private static let lingerGrace: TimeInterval = 0.1
    /// 换档时内容交接的时长。比尺寸那条曲线短，让尺寸去带动感。
    private static let stageFade: TimeInterval = 0.12

    private struct FloatStage: Equatable {
        enum Kind: Equatable {
            case name(String)
            case preview(PreviewTarget)
            case list(FloatPanel)
        }
        let kind: Kind
        /// 从条上哪一格长出来
        let anchorX: CGFloat

        var isList: Bool { if case .list = kind { return true } else { return false } }
    }

    /// 此刻该显示哪一档。三档互斥，按信息量从多到少挑。
    private func floatStage(_ layout: BarLayout) -> FloatStage? {
        guard !model.hidden else { return nil }
        if let panel, let content = panelContent(panel.kind, in: layout), !content.windows.isEmpty {
            return FloatStage(kind: .list(panel.kind), anchorX: panel.anchorX)
        }
        if let preview {
            return FloatStage(kind: .preview(preview), anchorX: preview.anchorX)
        }
        if let pill = pillTarget(layout) {
            return FloatStage(kind: .name(pill.text), anchorX: pill.anchorX)
        }
        return nil
    }

    private func floatSize(_ stage: FloatStage, in size: CGSize, layout: BarLayout) -> CGSize {
        guard case .list(let kind) = stage.kind else {
            return PreviewCard.size(title: cardTitle(stage), detail: cardDetail(stage))
        }
        guard let content = panelContent(kind, in: layout) else { return .zero }
        return CGSize(width: WindowPanel.width(content.windows.count, available: size.width),
                      height: WindowPanel.height(content.windows.count, available: size.width))
    }

    private func cardTitle(_ stage: FloatStage) -> String {
        switch stage.kind {
        case .name(let text): return text
        case .preview(let target): return target.window.title
        case .list: return ""
        }
    }

    /// nil = 还只是名字那一档
    private func cardDetail(_ stage: FloatStage) -> PreviewCard.Detail? {
        guard case .preview(let target) = stage.kind else { return nil }
        return PreviewCard.Detail(window: target.window,
                                  appName: target.appName,
                                  image: thumbnails.images[target.window.id],
                                  unavailable: thumbnails.unavailable.contains(target.window.id))
    }

    private func floatContent(_ stage: FloatStage, in layout: BarLayout,
                              available: CGFloat) -> some View {
        // 分支一律留在这个容器**里面**。让分支出现在最外层，`.frame` 就挂在了一个
        // 换档即换 identity 的视图上——没有起点可以插值，尺寸于是根本不变，
        // 整块只剩淡入淡出。实测如此：名字与预览并进同一分支之后就连贯了，
        // 而一排窗口那一档当时还是外层分支，仍旧在闪。
        ZStack(alignment: .bottom) {
            floatBody(stage, in: layout, available: available)
        }
    }

    @ViewBuilder
    private func floatBody(_ stage: FloatStage, in layout: BarLayout,
                           available: CGFloat) -> some View {
        if case .list(let kind) = stage.kind {
            if let content = panelContent(kind, in: layout) {
                WindowPanel(windows: content.windows,
                            heading: content.heading,
                            subheading: content.subheading,
                            color: content.color,
                            available: available,
                            thumbnails: thumbnails,
                            icon: { model.world.icon(for: $0) },
                            // 键盘选中的那张卡与悬停用同一套高亮：面板里此刻只会有
                            // 一个焦点，两条来路不必长得不一样
                            hovered: { hoveredItem == "panel.w\($0)"
                                || (model.keyVisible && model.keySelection == $0) },
                            onHover: { id, inside in
                                let key = "panel.w\(id)"
                                if inside { hoveredItem = key }
                                else if hoveredItem == key { hoveredItem = nil }
                            },
                            onRecall: { model.world.recall($0) },
                            onMenuZone: { model.setMenuZone("panel.w\($0)", $1) },
                            metrics: layout.metrics,
                            drag: panelDrag)
                    // 换档时两份内容会同时在场。让它们各自快进快出，把这段重叠压短，
                    // 动感就交给尺寸那条更长的曲线去带——两者同速的话，中间那一段
                    // 看到的是两层内容互相透出来。
                    .transition(.opacity.animation(.easeOut(duration: Self.stageFade)))
            }
        } else {
            // 名字与预览必须落在同一个分支里。分成两个分支，SwiftUI 就当它们是两棵树，
            // 换档时只剩互相淡入淡出可做。同一棵树，标题才是同一个 Text、待在同一个位置，
            // 缩略图从它上方长出来。
            // `.task` 也必须无条件挂：只挂在其中一档上，修饰符链一变，identity 照样断。
            PreviewCard(title: cardTitle(stage), detail: cardDetail(stage))
                .task(id: cardDetail(stage)?.window.id) {
                    guard let id = cardDetail(stage)?.window.id else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        thumbnails.capture(id)
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: Self.stageFade)))
        }
    }

    /// 键盘选中的那个窗口该不该长出预览卡。收在浮层里的不长——浮层的卡片自带缩略图。
    private func syncKeyPreview(_ layout: BarLayout) {
        guard model.keyVisible, let id = model.keySelection, model.keyPanel == nil,
              let window = model.world.windows.first(where: { $0.id == id }),
              let item = layout.items.first(where: { keySelected($0) }),
              case .window(let cell) = item, cell.id == id,
              let anchorX = cellAnchors[item.id]
        else {
            schedulePreview(nil, from: hoveredCell ?? 0)
            return
        }
        schedulePreview(PreviewTarget(window: window, appName: cell.appName, anchorX: anchorX),
                        from: id)
    }

    /// 名牌此刻该报谁的名字。nil = 不出名牌。
    private func pillTarget(_ layout: BarLayout) -> (text: String, anchorX: CGFloat)? {
        // 让不让位给信息更多的那两档，由 `floatStage` 统一定，这里只管报名字。
        // 拖拽最优先：手上正拎着文件，停在哪一格上就是此刻唯一要紧的事。
        if let id = model.dragOverWindow {
            guard let item = layout.items.first(where: { item in
                      if case .window(let cell) = item { return cell.id == id } else { return false }
                  }),
                  let anchorX = cellAnchors[item.id], let text = name(of: item)
            else { return nil }
            return (text, anchorX)
        }
        // 键盘会话次之。指针可能停在某处一动不动，那不是用户此刻的注意力所在。
        if model.keyVisible {
            guard let item = layout.items.first(where: { keySelected($0) }),
                  let anchorX = cellAnchors[item.id], let text = name(of: item)
            else { return nil }
            return (text, anchorX)
        }
        guard let hoveredItem, let anchorX = cellAnchors[hoveredItem],
              let item = layout.items.first(where: { $0.id == hoveredItem }),
              let text = name(of: item)
        else { return nil }
        return (text, anchorX)
    }

    /// 一格叫什么。窗口给完整标题——条上那一份是剥掉共同首尾段又压过宽度的片段。
    private func name(of item: BarItem) -> String? {
        switch item {
        case .window(let cell): return cell.window.title
        case .dormant(let app): return app.name
        case .cluster(let cluster): return cluster.heading
        case .launcher(let url), .folder(let url): return model.world.displayName(of: url)
        case .trash: return model.world.trashFull ? "废纸篓（非空）" : "废纸篓"
        case .overflow(let windows): return "更多窗口（\(windows.count) 个）"
        case .separator, .notice: return nil
        }
    }

    /// 这一格是不是键盘切换此刻选中的那个窗口所在之处。
    /// 选中的窗口若收在簇、标签组或溢出区里，高亮的是收着它的那一格，
    /// 具体是其中哪一个由随之打开的浮层给出。
    private func keySelected(_ item: BarItem) -> Bool {
        // 门禁收在这里，调用点因此不必各自记得加：没显形的会话在视觉上不存在
        guard model.keyVisible, let id = model.keySelection else { return false }
        switch item {
        case .window(let cell):
            return cell.id == id || cell.tabs.contains { $0.id == id }
        case .cluster(let cluster):
            return cluster.windows.contains { $0.id == id }
        case .overflow(let windows):
            return windows.contains { $0.id == id }
        default:
            return false
        }
    }

    private func backing(_ id: String, key: AppKey? = nil) -> Backing {
        if pressedItem == id { return .bright }
        if hoveredItem == id { return .light }
        if let key, hoveredApp == key { return .linked }
        return .none
    }

    /// 一格。与 itemView 分开，是因为面板里要复用它——
    /// 让 itemView 递归调用自己，SwiftUI 的不透明返回类型推不出来。
    /// 窗口格与固定 App 槽位。两者共用一棵视图树，差异全部表达成可动画的属性——
    /// 「同一个位置上的同一件事」在启动前后不该换一棵树（计划书 §3.1）。
    private func slotCell(_ item: BarItem, metrics: BarMetrics) -> some View {
        let slot = Slot(item, model: model)
        return DockCell(slot: slot, metrics: metrics,
                        backing: backing(item.id, key: slot.key),
                        onHover: { anchorX in
                            guard let anchorX else {
                                if hoveredItem == item.id { hoveredItem = nil }
                                if hoveredApp == slot.key { hoveredApp = nil }
                                guard let cell = slot.cell else { return }
                                cell.tabs.isEmpty ? schedulePreview(nil, from: cell.id)
                                                  : dismissPanel()
                                return
                            }
                            hoveredItem = item.id
                            hoveredApp = slot.key
                            guard let cell = slot.cell else { return }
                            // 收着标签的格子里有好几样东西，浮出的应该是「这一格里有什么」，
                            // 而不是宿主窗口一个人的预览卡
                            guard cell.tabs.isEmpty else {
                                schedulePanel(.tabs(cell.id), anchorX: anchorX)
                                return
                            }
                            schedulePreview(PreviewTarget(window: cell.window,
                                                          appName: cell.appName,
                                                          anchorX: anchorX),
                                            from: cell.id)
                        },
                        onTap: { tap(slot) })
            .help(slot.help)
    }

    private func tap(_ slot: Slot) {
        guard let cell = slot.cell else {
            // 正在启动的 App 再点没有意义：它还没到达，也就谈不上「已在眼前」
            guard let app = slot.app, !slot.bouncing else { return }
            model.world.launch(app, on: model.display)
            return
        }
        // 点已经在前台的窗口 = 收起它。没有 AX 引用的窗口最小化不了，
        // 但它也不可能是前台窗口，走召回。
        if slot.isFront, cell.window.element != nil {
            _ = minimizeWindow(cell.window)
        } else {
            model.world.recall(cell.window)
        }
    }

}

/// 条上方那一层浮出来的面板是谁的。
enum FloatPanel: Equatable {
    case cluster(Int)
    /// 收拢了原生标签页的那一格
    case tabs(CGWindowID)
    case overflow
}

// MARK: - 顶层项：窗口格 / 簇 / 单图标项
//
// 三者共用同一个盒模型，图标因此天然落在同一条基线上。计划书 §3.1：
// 任何「只给某一类项加一行东西」的设计都会破坏这条基线。

/// 不带格子的项：启动台、固定文件夹、垃圾桶、无窗口的固定 App
private struct BareItem: View {
    let icon: NSImage?
    let metrics: BarMetrics
    let backing: Backing
    /// 正在启动：图标上下弹跳，与系统 Dock 同义
    var bouncing = false
    var badge: String? = nil

    var body: some View {
        AppIcon(image: icon, size: metrics.icon, minimized: false)
            .badge(badge, size: metrics.icon)
            .offset(y: bouncing ? -8 : 0)
            .animation(bouncing
                        ? .easeInOut(duration: 0.42).repeatForever(autoreverses: true)
                        : .spring(response: 0.3, dampingFraction: 0.7),
                       value: bouncing)
            .padding(metrics.cellInset)
            .background { BackingFill(backing: backing, radius: metrics.cellRadius) }
            .contentShape(Rectangle())
    }
}

/// 条上的一格：一个窗口。
///
/// 底色由格子自己画，不再由「一段」罩着——分开画的代价很实在：拖一格出去，
/// 图标走了、底留在原地。一格就是一格，前台窗口整格用亮底，不再套内层。
/// 一格里要画的全部东西。窗口格与未打开的 App 槽位摊平成同一组属性，
/// 视图因此只有一棵树，状态迁移是属性插值，不是结构替换。
struct Slot {
    let key: AppKey
    let icon: NSImage?
    let label: String?
    let labelWidth: CGFloat
    let showsDot: Bool
    let tabs: Int
    let badge: String?
    let activity: Activity?
    let minimized: Bool
    let isFront: Bool
    /// 正在启动：图标弹跳，与系统程序坞同义
    let bouncing: Bool
    let help: String
    /// 有窗口的那一形态。nil = 这个 App 此刻一个窗口都没有。
    let cell: BarWindow?
    let app: DormantApp?

    init(_ item: BarItem, model: BarModel) {
        switch item {
        case .window(let cell):
            self.key = cell.key
            self.icon = model.world.icon(for: cell)
            self.label = cell.label
            self.labelWidth = cell.labelWidth
            self.showsDot = cell.showsDot
            self.tabs = cell.tabs.count
            // App 级的东西只挂在该 App 的第一格上，不逐格重复
            self.badge = cell.leadsApp ? model.world.badges[cell.bundleID ?? ""] : nil
            self.activity = cell.leadsApp ? model.world.activities[cell.pid] : nil
            self.minimized = cell.window.minimized
            // 会话显形期间不再标注前台。此刻条回答的是「松手会去哪儿」，不是「现在在哪儿」，
            // 前台那一格的亮底留着只会和选中底色抢读。
            self.isFront = cell.id == model.world.frontWindow && !model.keyVisible
            self.bouncing = false
            self.help = cell.window.title
            self.cell = cell
            self.app = nil
        case .dormant(let app):
            self.key = AppKey.bundle(app.bundleID)
            self.icon = model.world.icon(app: app.url, bundleID: app.bundleID)
            self.label = nil
            self.labelWidth = 0
            self.showsDot = false
            self.tabs = 0
            self.badge = model.world.badges[app.bundleID]
            self.activity = nil
            self.minimized = false
            self.isFront = false
            self.bouncing = model.world.launching.contains(app.bundleID)
            self.help = app.name
            self.cell = nil
            self.app = app
        default:
            // itemView 只把这两个 case 交给这里，其余项各有各的形状
            self.key = AppKey.process(0)
            self.icon = nil
            self.label = nil
            self.labelWidth = 0
            self.showsDot = false
            self.tabs = 0
            self.badge = nil
            self.activity = nil
            self.minimized = false
            self.isFront = false
            self.bouncing = false
            self.help = ""
            self.cell = nil
            self.app = nil
        }
    }
}

private struct DockCell: View {
    @Environment(\.colorScheme) private var scheme
    let slot: Slot
    let metrics: BarMetrics
    let backing: Backing
    let onHover: (CGFloat?) -> Void
    let onTap: () -> Void

    @State private var frame: CGRect = .zero

    var body: some View {
        HStack(spacing: metrics.labelGap) {
            icon
            label
        }
        .padding(metrics.cellInset)
        .background { BackingFill(backing: slot.isFront ? .bright : backing,
                                  radius: metrics.cellRadius) }
        // 活动状态画在格子边缘上，不额外占一行——那会破坏统一盒模型（§3.1）
        .overlay { edge }
        // 计划书 §3：最小化的格子原地变灰，绝不挪位
        .opacity(slot.minimized ? 0.42 : 1)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("moor.root")) }
            action: { frame = $0 }
        .onHover { onHover($0 ? frame.midX : nil) }
        .onTapGesture(perform: onTap)
    }

    private var icon: some View {
        AppIcon(image: slot.icon, size: metrics.icon, minimized: slot.minimized)
            .badge(slot.badge, size: metrics.icon)
            .overlay(alignment: .bottom) {
                if slot.showsDot { RunDot(drop: metrics.dotDrop) }
            }
            // 收着几个标签就标几。落在左上角：右上角是未读角标的位置
            .overlay(alignment: .topLeading) {
                if slot.tabs > 0 { CountBadge(text: "\(slot.tabs)", scheme: scheme) }
            }
            .modifier(LaunchBounce(bouncing: slot.bouncing, height: metrics.icon * 0.36))
    }

    @ViewBuilder
    private var label: some View {
        if let text = slot.label {
            // 两行折行，排不下末尾截断。
            // 宽度由 LabelWidths 一次算准，不交给 frame(maxWidth:)：
            // 外层 fixedSize 会把它的理想宽取成上限值，短标题也会占满。
            Text(text)
                .font(.system(size: BarMetrics.labelFontSize, weight: .medium))
                .lineLimit(BarMetrics.labelLines)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary.opacity(slot.minimized ? 0.62 : 0.9))
                // 上限由降级阶梯定（③压的就是它），视图与宽度计算读同一个值
                .frame(width: metrics.label(slot.labelWidth), alignment: .leading)
                // 标题靠紧自己的图标，与下一格拉开——归属只剩邻近性可依据
                .padding(.trailing, metrics.labelTrailing - metrics.cellInset)
                // App 开出第二个窗口时，这一格是原地长出标题区的：格子沿用 App 的
                // 身份（见 BarItem.id），SwiftUI 因此走过渡而不是拆掉重建。
                .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var edge: some View {
        if let activity = slot.activity {
            ActivityEdge(activity: activity, radius: metrics.cellRadius)
                .help(activity.summary ?? "")
        }
    }
}

/// 启动弹跳。相位由 `bouncing` 驱动，而它来自模型（`BarModel.launching`），不是视图自己的
/// 状态：视图万一被重建，动画顶多闪一帧，不会从头再来。
///
/// 三段关键帧照系统程序坞的节奏走：弹出去快、落下来带重力、落地停一拍再起跳，一轮约 0.9 秒。
/// 对称的来回读起来像「在呼吸」，不像「在等它起来」。
///
/// 每一处的类型都写死成 `CGFloat`：这套关键帧 DSL 的泛型很深，`initialValue` 给成 Double
/// 而轨道里是 CGFloat 的话，约束求解会指数爆炸——实测那一版把整台机器的内存吃光。
struct LaunchBounce: ViewModifier {
    private static let rise: TimeInterval = 0.24
    private static let fall: TimeInterval = 0.30
    private static let rest: TimeInterval = 0.34
    /// 一轮的时长。模型据此让最后一轮跳完再落地（见 `BarModel.landBounce`）。
    static let cycle = rise + fall + rest

    let bouncing: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat.zero, repeating: bouncing) { view, lift in
            // 这里必须显式落地：`repeating` 转 false 时关键帧就地停住，不会把值收回起点，
            // 图标会卡在抬起的位置（实测）。正常情况下这一步是空操作——模型只在
            // 一轮的末尾撤掉 bouncing，那时 lift 本来就是 0。
            view.offset(y: bouncing ? -lift : 0)
        } keyframes: { (_: CGFloat) in
            KeyframeTrack {
                SpringKeyframe(height, duration: Self.rise,
                               spring: Spring(duration: 0.22, bounce: 0.2))
                CubicKeyframe(CGFloat.zero, duration: Self.fall,
                              startVelocity: 0, endVelocity: -2)
                LinearKeyframe(CGFloat.zero, duration: Self.rest)
            }
        }
    }
}

/// 簇在条上的样子：永远折叠的一格。
///
/// 封面是最近活跃的成员，满尺寸；后面的成员向右偏移露出一条边，最多三层，
/// 叠不下的交给数量角标。底部一条短色线占普通窗口小圆点的位置，标簇身份。
/// 标题区例外地用结构化两行（簇名 + N 个窗口）——这两个都是系统自有字段，
/// 不像窗口标题那样只能原样直排。
private struct FoldedCluster: View {
    @Environment(\.colorScheme) private var scheme
    let cluster: BarCluster
    let icons: [NSImage?]
    let metrics: BarMetrics
    let backing: Backing

    var body: some View {
        HStack(spacing: cluster.showsName ? metrics.labelGap : 0) {
            deck
            if cluster.showsName {
                VStack(alignment: .leading, spacing: 1) {
                    Text(cluster.heading)
                        .font(.system(size: BarMetrics.labelFontSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(cluster.subheading)
                        .font(.system(size: BarMetrics.labelFontSize - 1))
                        .foregroundStyle(.secondary)
                }
                .frame(width: metrics.label(cluster.labelWidth), alignment: .leading)
                .padding(.trailing, metrics.labelTrailing - metrics.cellInset)
            }
        }
        .padding(metrics.cellInset)
        .background { BackingFill(backing: backing, radius: metrics.cellRadius) }
        .contentShape(Rectangle())
    }

    private var deck: some View {
        ZStack(alignment: .leading) {
            // 后往前画：封面压在最上面
            ForEach(Array(icons.prefix(cluster.layers).enumerated()).reversed(), id: \.offset) {
                index, image in
                AppIcon(image: image, size: metrics.icon, minimized: false)
                    // 越靠后越小一点，读起来才是「深度」而不是并排
                    .scaleEffect(1 - CGFloat(index) * 0.07)
                    .overlay {
                        // 浅色桌面上两层同色图标会糊在一起，露出的那条边需要一条极细的界线。
                        // 内缩一成是标准 macOS 图标网格里方形的位置。
                        if index > 0 {
                            RoundedRectangle(cornerRadius: metrics.icon * 0.22, style: .continuous)
                                .strokeBorder(ink(scheme, 0.5, 0.25), lineWidth: 0.5)
                                .padding(metrics.icon * 0.1)
                                .scaleEffect(1 - CGFloat(index) * 0.07)
                        }
                    }
                    .shadow(color: .black.opacity(0.24), radius: 2, x: -1.5, y: 0)
                    .offset(x: metrics.icon * BarMetrics.deckReveal * CGFloat(index))
                    .zIndex(Double(-index))
            }
        }
        .frame(width: deckWidth(cluster.layers, icon: metrics.icon),
               height: metrics.icon, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if cluster.overflow > 0 { CountBadge(text: "+\(cluster.overflow)", scheme: scheme) }
        }
        .overlay(alignment: .bottom) {
            ClusterLine(color: cluster.color, width: metrics.icon * 0.36,
                        drop: metrics.dotDrop)
        }
    }
}

/// 叠不下的成员数。中性胶囊，不用未读角标那套红底——红色在条上有专属含义。
private struct CountBadge: View {
    let text: String
    let scheme: ColorScheme

    var body: some View {
        Text(text)
            .font(.system(size: BarMetrics.badgeFontSize, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.92))
            .padding(.horizontal, 4)
            .frame(minWidth: BarMetrics.badgeMinWidth, minHeight: 15)
            .background {
                Capsule().fill(ink(scheme, 0.28, 0.14))
                    .overlay(Capsule().strokeBorder(ink(scheme, 0.2, 0.1), lineWidth: 0.5))
            }
    }
}

/// 簇的身份色线，占普通窗口小圆点的位置。
private struct ClusterLine: View {
    let color: ClusterColor
    let width: CGFloat
    let drop: CGFloat

    var body: some View {
        Capsule()
            .fill(color.tint)
            .frame(width: width, height: BarMetrics.dotSize)
            .offset(y: drop)
    }
}

/// 活动状态：有确定进度时格子边缘走进度环，否则边缘呼吸。计划书 §3。
private struct ActivityEdge: View {
    let activity: Activity
    let radius: CGFloat

    @State private var breathing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let progress = activity.progress {
                shape.trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                shape.stroke(.primary.opacity(breathing ? 0.7 : 0.16), lineWidth: 2)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                               value: breathing)
                    .onAppear { breathing = true }
            }
        }
        .padding(BarMetrics.backingInset)
    }
}

/// 底色三档。计划书 §3.1 的表格。
///
/// 底色向内缩一圈画：格子之间没有布局意义上的缝（那样的缝是全时段的），
/// 缝由这一圈内缩产生，只在底色真的出现时才看得见。
struct BackingFill<S: InsettableShape>: View {
    @Environment(\.colorScheme) private var scheme
    let backing: Backing
    let shape: S

    var body: some View {
        Group {
            switch backing {
            case .none:
                EmptyView()
            case .linked:
                // 比悬停轻一档：它只是「那边还有一个同 App 的窗口」，不该跟指针底下
                // 那一格抢注意力。
                shape.fill(ink(scheme, 0.05, 0.03))
            case .light:
                // 只填充，不描边。相邻两格的内侧描边会撞成一条竖线，
                // 看起来就成了窗口之间的分隔——§3.1 明写窗口之间一律不隔。
                shape.fill(ink(scheme, 0.11, 0.06))
            case .bright:
                shape.fill(ink(scheme, 0.22, 0.115))
                    .overlay(shape.strokeBorder(
                        LinearGradient(colors: [ink(scheme, 0.36, 0.18), .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5))
            case .focused:
                // 比前台再实一档。会话期间它是条上唯一亮着的东西，其余项一律压暗，
                // 所以这一档不必再靠描边去争——描边在 macOS 里是焦点环与拖放接收区的
                // 语汇，用在这里会读成「可以往这儿放东西」。
                shape.fill(ink(scheme, 0.34, 0.19))
                    .overlay(shape.strokeBorder(
                        LinearGradient(colors: [ink(scheme, 0.48, 0.26), .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5))
            }
        }
        .padding(BarMetrics.backingInset)
    }
}

/// 运行指示点：这里有窗口可以召回。分层的理由见 `Backing`。
///
/// §3.1 当初否掉圆点的理由是「需要额外一行」——盒收紧到「图标 + 4」之后，
/// 图标下沿与条底之间空出 10pt，点落在这条带里不额外占行，那个理由不再成立。
private struct RunDot: View {
    /// 从图标下沿往下落多少。挂在图标上而不是整格上：带标签的格子横跨图标与标签，
    /// 挂在格子上点会飘到标签底下。
    let drop: CGFloat

    var body: some View {
        Circle()
            .fill(.primary.opacity(0.65))
            .frame(width: BarMetrics.dotSize, height: BarMetrics.dotSize)
            .offset(y: drop)
    }
}

extension BackingFill where S == RoundedRectangle {
    init(backing: Backing, radius: CGFloat) {
        self.init(backing: backing,
                  shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 未读角标。数据来自 App 自带的 dock tile 插件，或系统程序坞对应项的状态文字。
private struct Badge: ViewModifier {
    let text: String?
    let size: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: max(9, size * 0.20), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, max(4, size * 0.09))
                    .frame(minWidth: size * 0.36, minHeight: size * 0.36)
                    .background(.red, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .offset(x: size * 0.16, y: -size * 0.12)
                    .fixedSize()
            }
        }
    }
}

private extension View {
    func badge(_ text: String?, size: CGFloat) -> some View {
        modifier(Badge(text: text, size: size))
    }
}

struct AppIcon: View {
    @Environment(\.colorScheme) private var scheme
    let image: NSImage?
    let size: CGFloat
    let minimized: Bool

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(ink(scheme, 0.16, 0.10))
                    // 真图标自带约一成的透明边距，占位块也得留，不然紧排后它顶到邻格
                    .padding(size * 0.1)
            }
        }
        .frame(width: size, height: size)
        .saturation(minimized ? 0 : 1)
    }
}

// MARK: - 拖拽接线
//
// 可拖动的单位是窗口格、无窗口的 App、整个簇。窗口格住在 RunItem 里，拿不到 BarContent
// 的状态，所以把需要的几件事打包成闭包传下去，而不是把 RunItem 摊回 BarContent
// ——那会让 SwiftUI 的类型推导直接超时。

struct DragBinding {
    let record: (DragUnit, CGRect) -> Void
    let offset: (DragUnit) -> CGSize
    let lifted: (DragUnit) -> Bool
    let merging: (DragUnit) -> Bool
    /// 这一格已经交给屏幕上那块落点了（分屏），条上只留一个压暗的占位。
    let placing: (DragUnit) -> Bool
    let changed: (DragUnit, CGSize) -> Void
    let ended: (DragUnit) -> Void
}

extension View {
    /// 把一个视图接进拖拽层。
    ///
    /// 用 onTapGesture 而不是 Button：Button 会先把手势吃掉，结果要么拖不动，
    /// 要么拖完松手还顺带触发一次召回。
    func dragged(as unit: DragUnit, metrics: BarMetrics, drag: DragBinding) -> some View {
        let offset = drag.offset(unit)
        return self
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("moor.bar")) }
                action: { drag.record(unit, $0) }
            .offset(x: offset.width, y: offset.height)
            .scaleEffect(drag.placing(unit) ? 1
                         : (drag.lifted(unit) ? 1.08 : (drag.merging(unit) ? 1.05 : 1)))
            .opacity(drag.placing(unit) ? 0.35 : (drag.lifted(unit) ? 0.9 : 1))
            .zIndex(drag.lifted(unit) ? 1 : 0)
            // 让位要弹一下，被拖的那一格不能弹——给它加动画，它就追不上指针，
            // 视觉会落在落点判定后面，看起来就是「反馈和实际位置对不上」。
            .animation(drag.lifted(unit) ? nil
                        : .interactiveSpring(response: 0.26, dampingFraction: 0.78),
                       value: offset)
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: drag.lifted(unit))
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: drag.merging(unit))
            // 最小距离 0：按下也要拿到。阈值判定在 DragBinding.changed 里。
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("moor.bar"))
                .onChanged { drag.changed(unit, $0.translation) }
                .onEnded { _ in drag.ended(unit) })
            .overlay {
                if drag.merging(unit) {
                    let shape = RoundedRectangle(cornerRadius: metrics.cellRadius,
                                                 style: .continuous)
                    shape.fill(.primary.opacity(0.14))
                        .overlay(shape.strokeBorder(.primary.opacity(0.4), lineWidth: 1.5))
                        .padding(BarMetrics.backingInset)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    /// 按下态与点击，给不可拖动的项用（启动台、固定文件夹、废纸篓）。
    ///
    /// 两者必须并在同一条手势里。单挂一条零距离的拖拽去取按下态，它会把另一条手势整个
    /// 吃掉：挂在内层就吃掉外层的 `onTapGesture`（点击失效，实测），可拖动的项挂了
    /// 则吃掉外层负责重排的那条（拖拽失效）——后者的按下态因此并在重排手势里拿。
    func clickable(_ id: String, _ current: Binding<String?>,
                   action: @escaping () -> Void) -> some View {
        gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if current.wrappedValue != id { current.wrappedValue = id } }
            .onEnded { value in
                if current.wrappedValue == id { current.wrappedValue = nil }
                // 按下之后拖开再松手不算点击
                guard max(abs(value.translation.width), abs(value.translation.height))
                        < BarContent.dragThreshold else { return }
                action()
            })
    }

    /// 记下指针停在哪一项上。底色是瞬时态，需要知道「此刻是哪一格」。
    func hoverTracked(_ id: String, _ current: Binding<String?>) -> some View {
        onHover { inside in
            if inside {
                current.wrappedValue = id
            } else if current.wrappedValue == id {
                current.wrappedValue = nil
            }
        }
    }
}

extension View {
    /// 把这一项登记为可接收文件的落点。位置报给 model，由 `DropCatcher` 在 AppKit 层判定命中。
    func dropZone(_ id: String, model: BarModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("moor.root")) }
            action: { model.setDropZone(id, $0) }
    }
}

/// ⑤ 溢出入口。按控件画，不按簇画：没有堆叠、没有色线，只有一个指向后方的记号
/// 和一个数量角标——用户一眼就该看出这是条自己的功能按钮，不是谁悄悄建了一个组。
private struct OverflowEntry: View {
    @Environment(\.colorScheme) private var scheme
    let count: Int
    let metrics: BarMetrics
    let backing: Backing

    var body: some View {
        Image(systemName: "chevron.right.2")
            .font(.system(size: metrics.icon * 0.34, weight: .semibold))
            .foregroundStyle(ink(scheme, 0.55, 0.7))
            .frame(width: metrics.icon, height: metrics.icon)
            .overlay(alignment: .topTrailing) {
                CountBadge(text: "\(count)", scheme: scheme)
            }
            .padding(metrics.cellInset)
            .background { BackingFill(backing: backing, radius: metrics.cellRadius) }
            .contentShape(Rectangle())
    }
}

/// 格子飞向 / 飞出溢出入口。
private struct Flight: ViewModifier, Animatable {
    var dx: CGFloat
    var gone: Bool

    /// 只让位移参与插值：缩放与淡出跟着同一条曲线走，不必各自动画
    var animatableData: CGFloat {
        get { dx }
        set { dx = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(gone ? 0.24 : 1)
            .offset(x: gone ? dx : 0)
            .opacity(gone ? 0 : 1)
    }
}
