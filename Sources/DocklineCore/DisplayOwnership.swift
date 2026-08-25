import AppKit

// 窗口的显示器归属（计划书 §6 M5「对象归属」）。
//
// 判据是最大覆盖面积，不是窗口中心。横跨边界的窗口按中心判会在拖动过程中整格翻面，
// 而覆盖面积是连续量，配上一道迟滞余量就压得住抖动。
//
// 数据全部来自 CG 对账已经取回的 `kCGWindowBounds` 与 AX 定向刷新已经取回的几何，
// 不新增任何一次采样——计划书 §2 的稳态预算不变。

/// 一份屏幕快照，坐标系与窗口索引一致（全局左上原点、y 向下）。
///
/// 每轮取一次传进来，不逐窗口去问 `NSScreen`：归属判定要跑遍索引里的每个窗口。
public struct DisplayLayout {
    public struct Display {
        public let id: CGDirectDisplayID
        public let frame: CGRect

        public init(id: CGDirectDisplayID, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
    }

    public let displays: [Display]

    public init(displays: [Display]) { self.displays = displays }

    /// 只能在主线程取（`NSScreen.screens` 的要求）。
    public static func current() -> DisplayLayout {
        DisplayLayout(displays: NSScreen.screens.compactMap { screen in
            guard let id = displayID(screen) else { return nil }
            return Display(id: id, frame: flipY(screen.frame))
        })
    }

    /// 迁移门槛：新的覆盖面积要超过原归属者的这个倍数，才算真的搬过去了。
    /// 窗口被拖过边界时两边面积在 1:1 附近来回摆，这道余量把它压住。
    private static let switchMargin: CGFloat = 1.25

    /// - Parameter previous: 上一轮的归属。nil = 新窗口，直接取覆盖面积最大的那块。
    /// - Returns: nil 表示不知道——这个矩形与任何一块屏都不相交，且此前也没有归属。
    ///   调用方不要把它当成主屏，那是拿默认值盖住一个没答案的问题。
    public func owner(of bounds: CGRect, previous: CGDirectDisplayID?) -> CGDirectDisplayID? {
        var areas: [CGDirectDisplayID: CGFloat] = [:]
        for display in displays {
            let overlap = display.frame.intersection(bounds)
            guard !overlap.isNull else { continue }
            areas[display.id] = overlap.width * overlap.height
        }
        // 一块屏都不沾：窗口整体在可见区域之外（拔掉显示器的一瞬间、或被拖出边界）。
        // 它没有搬到别处去，沿用原归属。
        guard let best = areas.max(by: { $0.value < $1.value }) else { return previous }
        guard let previous, let held = areas[previous] else { return best.key }
        return best.value > held * Self.switchMargin ? best.key : previous
    }
}
