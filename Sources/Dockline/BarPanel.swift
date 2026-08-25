import AppKit
import DocklineCore
import SwiftUI

/// 计划书 §4：nonactivating 浮动面板，居中置底。
/// .canJoinAllSpaces + .fullScreenAuxiliary + 抬高 level，使其可浮于原生全屏之上。
///
/// 面板本身占满屏幕底部整条，玻璃条只是画在里面居中的一块。这样宽度变化、
/// 悬停展开、隐藏滑出全部由 SwiftUI 负责，一次 setFrame 都不必做——
/// M1 那套「格子数变了就同步改 window frame」的补丁连同它的裁切 bug 一并去掉了。
///
/// 成立的前提已实测：非 opaque 窗口的全透明像素不参与窗口服务器的命中测试，
/// 点击会穿透到下方窗口（alpha ≥ 0.005 就不再穿透）。
final class BarPanel: NSPanel {
    let model: BarModel

    /// 这条 bar 钉在哪块屏上。每块屏各有一条，谁也不搬家（计划书 §6 M5）。
    private var homeScreen: NSScreen

    /// 浮层要用的空间已经长出来了没有。见 `compactHeight`。
    private var expanded = false

    /// 常态高度：只装得下玻璃条本身。
    ///
    /// 面板原先一直是全高的，其中只有底部那一条是玻璃、其余全透明。截屏工具按窗口边界
    /// 出候选，于是屏幕下半部分始终压着一个我们的巨大候选框。浮层的高度因此改成按需长出来。
    /// 两个高度都按最大图标档算，不随当前条高变化——省掉「改图标尺寸要同时重摆面板」这条
    /// 容易漏的路径。
    private static let compactHeight: CGFloat =
        BarMetrics.maxIcon + 20 + BarMetrics.bottomGap * 2 + 8

    /// 还要容下浮在条上方的簇扇面与悬停预览卡。
    private static let panelHeight: CGFloat =
        BarMetrics.maxIcon + 20 + BarMetrics.bottomGap + 30
            // 簇的扇面浮在条的上方，预览卡再往上让一层——不留够，最上面那张会被面板裁掉
            + BarMetrics.maxIcon + 20 + 10
            + PreviewCard.imageHeight + 90

    init(world: World, screen: NSScreen) {
        model = BarModel(world: world)
        homeScreen = screen
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.panelHeight),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // 不开这个，面板收不到 mouse-moved，悬停展开与 .help 提示都不会触发
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        // Liquid Glass 自带投影；系统窗口投影会按整块（几乎全透明的）面板去算，只会添乱
        hasShadow = false
        // 拖放由 AppKit 层接住（见 DropCatcher），SwiftUI 宿主视图挂在它里面
        let catcher = DropCatcher(frame: NSRect(origin: .zero,
                                               size: NSSize(width: 800, height: Self.panelHeight)))
        catcher.autoresizesSubviews = true
        catcher.zone = { [weak model] point in model?.dropZone(at: point) }
        catcher.hover = { [weak model] id in model?.setFileDropTarget(id) }
        catcher.drop = { [weak model] id, urls in model?.acceptDrop(id, urls) ?? false }
        catcher.zoneReport = { [weak model] in model?.dropZoneReport ?? "（模型已释放）" }
        catcher.moved = { [weak model] point in model?.dragMoved(to: point) }
        catcher.left = { [weak model] in model?.dragLeft() }
        catcher.ended = { [weak model] in model?.dragEnded() }
        let host = NSHostingView(rootView: BarContent(model: model))
        host.frame = catcher.bounds
        host.autoresizingMask = [.width, .height]
        catcher.addSubview(host)
        contentView = catcher

        model.onFloatRoom = { [weak self] needed in self?.setExpanded(needed) }
        checkActiveAppearanceOverride()
        apply()
    }

    /// nonactivating 面板不该成为 key/main，否则会抢走用户当前 App 的焦点。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// SwiftUI 的右键处理发生在宿主内部；在窗口分发事件之前截住，确保动态菜单只在
    /// 用户真正右键的这一刻构造。落在透明区域时 `model.menu` 返回 nil，照常向下分发。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let contentView {
            // 落点按「离底边多远」交出去，与命中区的存法一致（见 `BarModel` 的命中区一节）
            let point = contentView.convert(event.locationInWindow, from: nil)
            if let menu = model.menu(at: point) {
                NSMenu.popUpContextMenu(menu, with: event, for: contentView)
                return
            }
        }
        super.sendEvent(event)
    }

    // MARK: 强制活跃外观（私有）
    //
    // 面板永远不是 key window，Liquid Glass 会据此按「非活跃」外观再压一层，
    // 看起来就厚、就灰——系统程序坞没有这个问题，因为它始终是活跃外观。
    // 这两个是 AppKit 的私有方法，覆盖它们即可；缺失时下面的自检会报出来。
    // 失效的后果只是材质偏厚，不影响任何功能。

    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    private func checkActiveAppearanceOverride() {
        for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus"]
        where !NSPanel.instancesRespond(to: Selector((name))) {
            Timeline.log("⚠️ 活跃外观覆盖 \(name) 不存在，材质会偏厚——系统更新可能改了内部名字")
        }
    }

    /// 这块屏的分辨率或排布变了，重摆一次。`NSScreen` 对象在屏幕参数变化时会被重建，
    /// 拿到的是一个新的、代表同一块屏的对象。
    func update(screen: NSScreen) {
        homeScreen = screen
        apply()
    }

    /// 浮层要用的空间：要画之前先把面板长上去，收起之后再落回常态高度。
    /// 面板贴着屏幕底边、往上长，条在 AppKit 坐标里的位置不变，因此不会打断悬停。
    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        apply()
    }

    /// 面板几何与窗口数无关，只跟屏和浮层的需要走。
    private func apply() {
        let height = expanded ? Self.panelHeight : Self.compactHeight
        // 必须先于 setFrame：视图侧随后上报的矩形要按这个高度换算成离底边的距离
        model.setPanelHeight(height)
        let frame = homeScreen.frame
        model.availableWidth = homeScreen.visibleFrame.width
        model.setBarDisplay(displayID(homeScreen))
        // 根坐标系（面板左上角起）→ 屏幕左上原点坐标 的平移量。面板贴着屏幕底边、
        // 占满整宽，所以横向为 0，纵向就是屏幕高减去面板高。
        model.setRootOffset(CGPoint(x: 0, y: homeScreen.frame.height - height))
        setFrame(NSRect(x: frame.minX, y: frame.minY,
                        width: frame.width, height: height),
                 display: true)
    }
}
