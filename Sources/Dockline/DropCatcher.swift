import AppKit
import DocklineCore

/// 文件拖放的接收方。
///
/// 不用 SwiftUI 的 `onDrop`：在这个 nonactivating 的浮动面板上它收不到访达的拖放，
/// 实机表现为拖上去毫无反应。改在 AppKit 层注册拖放类型，自己按落点找目标。
///
/// 它是面板的 contentView，SwiftUI 的宿主视图挂在它里面。宿主视图不再注册任何拖放类型，
/// 因此拖放会落到这一层。
final class DropCatcher: NSView {
    /// 落点（SwiftUI 根坐标系，原点在左上）-> 命中的项，nil 表示这个位置不接收
    var zone: ((CGPoint) -> String?)?
    /// 悬停到了哪一项。用于画高亮，离开时传 nil。
    var hover: ((String?) -> Void)?
    /// 松手。返回 false 表示没接住。
    var drop: ((String, [URL]) -> Bool)?
    /// 登记在册的接收区。只在落空时读一次，用来分辨「落点不对」和「接收区不对」。
    var zoneReport: (() -> String)?

    /// 上一次命中的目标。只在变化时记一笔——拖拽移动是连续事件，逐条记会把日志淹掉。
    private var lastTarget: String??

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不从 nib 加载") }

    /// 落点按「离窗口底边多远」交出去，与命中区的存法一致（见 `BarModel` 的命中区一节）。
    /// 不换算成左上原点：那一步要减去 `bounds.height`，而面板的高度是会变的。
    private func point(_ sender: NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Timeline.log("拖放进入  \(urls(sender).count) 个文件")
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = point(sender)
        let target = zone?(location)
        if lastTarget != target {
            lastTarget = target
            Timeline.log(String(format: "拖放经过  目标 %@  位置 (%.0f, %.0f)",
                                target ?? "—", location.x, location.y))
        }
        hover?(target)
        return target == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        lastTarget = nil
        hover?(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        lastTarget = nil
        hover?(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let location = point(sender)
        let files = urls(sender)
        guard let target = zone?(location), !files.isEmpty else {
            Timeline.log(String(format: "⚠️ 拖放落空  位置 (%.1f, %.1f)  文件 %d 个  接收区 %@",
                                location.x, location.y, files.count,
                                zoneReport?() ?? "（没登记）"))
            return false
        }
        Timeline.log("拖放松手  目标 \(target)  \(files.count) 个文件")
        return drop?(target, files) ?? false
    }
}
