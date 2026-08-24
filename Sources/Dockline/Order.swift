import AppKit
import DocklineCore

/// 窗口区的一个元素：一个窗口，或一个此刻没有窗口的 App 占位。
///
/// 这是排布的单位。App 不再拥有窗口——收起、簇、固定槽位都从这份顺序推导出来，
/// 而不是先按 App 分好桶再排桶（计划书 §3「同 App 窗口相邻，纯视觉聚拢，可自由拖散」）。
enum BarElement: Hashable {
    case window(CGWindowID)
    case app(AppKey)
}

/// 窗口区的顺序。会话内窗口级，跨重启只恢复到 App 级——
/// 窗口级的持久化需要一个跨重启稳定的窗口身份，那还是第 9 节里未解的问题。
final class WindowOrder {
    private(set) var elements: [BarElement] = []
    /// 每个窗口属于谁。窗口关掉之后还要用它决定「这个位置该不该留给占位」。
    private var owner: [CGWindowID: AppKey] = [:]

    /// 与现实对齐。
    /// - Parameters:
    ///   - placeholders: 此刻没有窗口、但要占位的 App（固定的，或本会话开过窗口的）
    ///   - rank: 跨重启的粗恢复用：冷启动时按记忆中的 App 顺序铺开
    func reconcile(windows: [IndexedWindow], placeholders: Set<AppKey>,
                   rank: (AppKey) -> Int) {
        for window in windows { owner[window.id] = window.appKey }
        let live = Set(windows.map(\.id))
        let appsWithWindows = Set(windows.map(\.appKey))

        var result: [BarElement] = []
        var placed = Set<AppKey>()

        for element in elements {
            switch element {
            case .window(let id) where live.contains(id):
                result.append(element)
            case .window(let id):
                // 窗口没了。它所属的 App 若还要占位，占位就地顶上——位置是用户的空间记忆，
                // 关掉最后一个窗口不该让这个 App 跳到末尾去。
                guard let key = owner[id], placeholders.contains(key), !placed.contains(key) else {
                    owner[id] = nil
                    continue
                }
                placed.insert(key)
                result.append(.app(key))
            case .app(let key):
                // 已经开出窗口的 App，占位要留到下面被它的窗口就地顶掉——
                // 在这里丢掉的话，「固定 App 启动后原地展开」就落空了，窗口只能追加到末尾。
                guard !placed.contains(key),
                      placeholders.contains(key) || appsWithWindows.contains(key)
                else { continue }
                placed.insert(key)
                result.append(.app(key))
            }
        }

        // 新窗口按记忆中的 App 位次先后进场。冷启动时这就是「跨重启的粗恢复」；
        // 平时一次只来一两个，排不排都一样。
        let ordered = windows
            .filter { !result.contains(.window($0.id)) }
            .enumerated()
            .sorted {
                let (a, b) = (rank($0.element.appKey), rank($1.element.appKey))
                return a == b ? $0.offset < $1.offset : a < b
            }
            .map(\.element)

        for window in ordered {
            let key = window.appKey
            if let index = result.firstIndex(of: .app(key)) {
                // 固定 App 启动后原地展开（计划书 §3）
                result[index] = .window(window.id)
            } else if let last = result.lastIndex(where: {
                guard case .window(let id) = $0 else { return false }
                return owner[id] == key
            }) {
                // 同 App 相邻是默认，不是不变量——拖散之后就各归各位
                result.insert(.window(window.id), at: last + 1)
            } else {
                result.append(.window(window.id))
            }
        }

        // 尚未出现过的占位（例如刚固定的 App）。按记忆中的位次进场，
        // placeholders 是个集合，直接遍历的话顺序是不确定的。
        for key in placeholders.sorted(by: { rank($0) < rank($1) })
        where !placed.contains(key) && !appsWithWindows.contains(key) {
            result.append(.app(key))
        }

        // 兜底：有窗口却没被顶掉的占位不该留下（该 App 的窗口都是老面孔时会出现）
        elements = result.filter {
            guard case .app(let key) = $0 else { return true }
            return !appsWithWindows.contains(key)
        }
        owner = owner.filter { live.contains($0.key) || placeholders.contains($0.value) }
    }

    /// 拖拽落地。target 为 nil 表示落到末尾。
    func move(_ element: BarElement, before target: BarElement?) {
        elements.removeAll { $0 == element }
        if let target, let index = elements.firstIndex(of: target) {
            elements.insert(element, at: index)
        } else {
            elements.append(element)
        }
    }

    /// 把一个窗口挪到另一个窗口的紧后面。成簇时用：簇要落在成员原本的位置上。
    func place(_ element: BarElement, after target: BarElement) {
        elements.removeAll { $0 == element }
        guard let index = elements.firstIndex(of: target) else {
            elements.append(element)
            return
        }
        elements.insert(element, at: index + 1)
    }

    /// 跨重启要存的东西：由窗口顺序推导出的 App 顺序。
    var appOrder: [String] {
        var seen: [String] = []
        for element in elements {
            let key: AppKey?
            switch element {
            case .window(let id): key = owner[id]
            case .app(let app): key = app
            }
            guard let bundleID = key?.bundleID, !seen.contains(bundleID) else { continue }
            seen.append(bundleID)
        }
        return seen
    }
}

extension IndexedWindow {
    var appKey: AppKey { bundleID.map(AppKey.bundle) ?? .process(pid) }
}
