import AppKit
import DocklineCore

/// 一条上报是谁发来的。
///
/// 这是**上报方的身份**，与它显示在哪一格（`StatusTarget`）分开。分开是因为两者的
/// 变化来源不同：同一个会话从头到尾是同一条上报，而它落在哪扇窗口上要靠推断，推断
/// 还可能改口。混在一起的话，重新绑定就成了「换了一条上报」，状态会跟着断。
enum ReportKey: Hashable {
    /// 上报方自报的会话标识。Claude Code 的 hook 每个事件都带 `session_id`。
    case session(String)
    /// 没有会话标识：整个 App 共用一条。同一个 App 里的两个终端标签页会互相覆盖，
    /// 这正是会话标识存在的理由。
    case host(pid_t)
    /// 上报方直接指名了窗口。手动指定与调试用，不需要推断。
    case window(CGWindowID)
}

/// 把一条上报落到哪一格（实时状态设计 §4.3）。
///
/// **主路是 cwd 与窗口标题的比对，前台焦点只当同分候选之间的裁判。** 两者的失败形状
/// 不同：cwd 对不上是**歧义**——当场就知道有几扇窗口对得上，可以拒绝绑定；而「取上报
/// 那一刻的前台焦点窗口」失败是**静默绑错且无界**，可能绑到另一个 App 的窗口上去。
/// 它还恰好踩在这个功能存在的理由上：用户提交完就切走，上报到达时读到的焦点已经是
/// 他切过去的那一扇。
enum SessionBinding {
    /// cwd 往上走几层就停。再往上是主目录、`/Users`、`/` 这类，与窗口标题撞上纯属巧合。
    private static let depth = 4

    /// 结果连同判据一起给出。判据要进日志——「cwd 匹配到底成不成」是设计文档 §8 里
    /// 待验的一条，靠实机读数回答，不靠估计。
    ///
    /// `why` 为 nil 表示沿用上一次的绑定，没有重新判断，也就没有什么可记的。
    struct Outcome {
        let target: StatusTarget
        let why: String?
    }

    static func resolve(host: pid_t, cwd: String?,
                        windows: [IndexedWindow], front: CGWindowID?) -> Outcome {
        let mine = windows.filter { $0.pid == host }
        guard !mine.isEmpty else {
            return Outcome(target: .app(host), why: "该进程名下没有窗口")
        }
        // 只有一扇窗口时不存在推断：上报来自这个 App 内部，它没有别处可去。
        if mine.count == 1 {
            return Outcome(target: .window(mine[0].id), why: "该 App 只有一扇窗口")
        }
        guard let cwd else {
            return Outcome(target: .app(host), why: "上报未带 cwd")
        }

        let segmented = mine.map {
            (window: $0, segments: Set(titleSegments(of: $0.title).map { $0.lowercased() }))
        }
        // 由深到浅：终端显示的常常是更深的那一层，而工作区窗口显示的是根目录名，
        // 先深后浅让两者都能命中，且命中的那一层越深，证据越强。
        for component in components(of: cwd) {
            let needle = component.lowercased()
            let hit = segmented.filter { $0.segments.contains(needle) }
            guard !hit.isEmpty else { continue }
            if hit.count == 1 {
                return Outcome(target: .window(hit[0].window.id),
                               why: "cwd「\(component)」唯一匹配 wid \(hit[0].window.id)")
            }
            // 同分了才轮到焦点，而且焦点必须是候选之一——它只做裁判，不许翻案。
            if let front, hit.contains(where: { $0.window.id == front }) {
                return Outcome(target: .window(front),
                               why: "cwd「\(component)」匹配 \(hit.count) 扇，取焦点 wid \(front)")
            }
            return Outcome(target: .app(host),
                           why: "cwd「\(component)」匹配 \(hit.count) 扇且焦点不在其中，退回 App 级")
        }
        return Outcome(target: .app(host), why: "cwd 与任何窗口标题都对不上")
    }

    /// cwd 由深到浅的各级目录名。
    static func components(of cwd: String) -> [String] {
        var path = (cwd as NSString).standardizingPath
        let home = NSHomeDirectory()
        var result: [String] = []
        while result.count < depth, path != "/", path != home {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { break }
            result.append(name)
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { break }
            path = parent
        }
        return result
    }
}
