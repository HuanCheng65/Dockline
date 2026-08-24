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
    let model = BarModel()

    /// 条当前所在的屏。多屏下条只有一条，跟着指针走（计划书 §3.1）。
    private var current: CGDirectDisplayID?

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

    init() {
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
        let host = NSHostingView(rootView: BarContent(model: model))
        host.frame = catcher.bounds
        host.autoresizingMask = [.width, .height]
        catcher.addSubview(host)
        contentView = catcher

        model.onFollowScreen = { [weak self] screen in self?.place(on: screen) }
        model.onFloatRoom = { [weak self] needed in self?.setExpanded(needed) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.layout()
                self?.model.screensChanged()
            }
        checkActiveAppearanceOverride()
        layout()
    }

    /// nonactivating 面板不该成为 key/main，否则会抢走用户当前 App 的焦点。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// SwiftUI 的右键处理发生在宿主内部；在窗口分发事件之前截住，确保动态菜单只在
    /// 用户真正右键的这一刻构造。落在透明区域时 `model.menu` 返回 nil，照常向下分发。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let contentView {
            let local = contentView.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: local.x, y: contentView.bounds.height - local.y)
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

    /// 屏幕参数变化时重摆。条留在原来那块屏上，那块屏没了才回到主屏。
    func layout() {
        guard let screen = NSScreen.screens.first(where: { displayID($0) == current })
                ?? NSScreen.main else { return }
        place(on: screen)
    }

    /// 滑下去到挪窗口之间等这么久。
    private static let slideOut: TimeInterval = 0.22

    /// 把面板摆到指定的屏。换屏时先让条滑下去，挪好了再滑上来——凭空闪现看不出它去了哪。
    func place(on screen: NSScreen) {
        guard let leaving = current, leaving != displayID(screen) else {
            apply(screen)
            return
        }
        model.setSliding(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideOut) { [weak self] in
            guard let self else { return }
            apply(screen)
            model.setSliding(false)
        }
    }

    /// 浮层要用的空间：要画之前先把面板长上去，收起之后再落回常态高度。
    /// 面板贴着屏幕底边、往上长，条在 AppKit 坐标里的位置不变，因此不会打断悬停。
    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        layout()
    }

    /// 面板几何与窗口数无关，只跟屏和浮层的需要走。
    private func apply(_ screen: NSScreen) {
        current = displayID(screen)
        let height = expanded ? Self.panelHeight : Self.compactHeight
        let frame = screen.frame
        model.availableWidth = screen.visibleFrame.width
        model.setBarDisplay(displayID(screen))
        // 根坐标系（面板左上角起）→ 屏幕左上原点坐标 的平移量。面板贴着屏幕底边、
        // 占满整宽，所以横向为 0，纵向就是屏幕高减去面板高。
        model.setRootOffset(CGPoint(x: 0, y: screen.frame.height - height))
        setFrame(NSRect(x: frame.minX, y: frame.minY,
                        width: frame.width, height: height),
                 display: true)
    }
}
