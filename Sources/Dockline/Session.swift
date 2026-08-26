import AppKit
import DocklineCore
import SwiftUI

/// 一格上的活动状态（计划书 §3、实时状态设计 §2–§3）。
///
/// **显著度只有三档，由「此刻谁在等谁」决定，不由状态种类决定。** 状态的种类以后还会加
/// （限额、下载、播放…），显著度不能跟着加——否则条上会同时出现数件争抢注意力的东西，
/// 而这个功能的本职是注意力路由：任务运行期间不打扰用户，需要用户的那一刻精确唤回。
struct Session: Equatable {
    /// 在等什么。**只有这一档允许高显著度。**
    enum Waiting: String, Equatable {
        case question, permission, plan, input

        var text: String { localized("activity.waiting.\(rawValue)") }
    }

    /// 停了。一次性事件，走「未读」语义：**停留到被看见为止，不自动消失**——
    /// 用户没看到就自行消失的通知，等于没有发出过。
    enum Outcome: String, Equatable {
        case done, failed, quota

        var mark: String {
            switch self {
            case .done: return "✓"
            case .failed: return "✗"
            case .quota: return "◷"
            }
        }

        /// 上报方没给摘要时用它。只留一个记号的话，看得见结果却读不出是什么结果。
        var text: String { localized("activity.outcome.\(rawValue)") }

        var tint: Color {
            switch self {
            case .done: return .green
            case .failed: return .red
            // 被限额与「完成」含义相反，也不是失败，给它自己的颜色（设计文档 §3）
            case .quota: return .orange
            }
        }
    }

    enum Salience: Equatable {
        /// 任务在跑，不需要用户介入。唯一要传达的是它仍在运行。
        case working
        /// 它在等你。
        case waiting(Waiting)
        /// 它停了。
        case finished(Outcome)

        /// 一格上撞了好几条上报时谁露面，以及同屏那一个胶囊归谁。数越小越优先。
        /// 等待排在最前——它是唯一允许高显著度的状态。
        var rank: Int {
            switch self {
            case .waiting: return 0
            case .finished: return 1
            case .working: return 2
            }
        }
    }

    /// 走过的一步。面板上那份近期动作，就是这些。
    ///
    /// **动作名与对象分开存，不拼成一句。** 面板把它们排成两栏，动作名竖直对齐——
    /// 三行读起来是一张表，而不是三句碰巧开头相似的话。拼好了就再也拆不开。
    struct Step: Equatable, Identifiable {
        let id: Int
        let tool: String
        let object: String?
        /// 完整的那一份（命令全文一类）。当前那一行给它，历史行给短的。
        let detail: String?
        /// 量化的结果：`+12 −5` 一类。缀在行尾右对齐。
        let metric: String?

        var verb: String { localized("activity.tool.\(tool)", fallback: tool) }
        var symbol: String { Session.symbol(tool: tool) }
    }

    /// 一次等着你批的授权（实时状态设计 §4.7）。
    ///
    /// 它与其余状态的分别在于**对面正停着等这一条**：面板上那两个按钮按下去，
    /// 答复顺着来时那条连接回去，那一步随即放行或被挡下。其余状态只是在陈述。
    struct Ask: Equatable, Identifiable {
        struct Line: Equatable, Identifiable {
            enum Sign: String, Equatable {
                case same = " "
                case added = "+"
                case removed = "−"
            }

            let id: Int
            let sign: Sign
            let text: String
        }

        let id: UUID
        let tool: String
        let object: String?
        /// 要判断的那一段：命令全文、增删行、要写进去的内容。
        let lines: [Line]
        /// 截掉了多少行。**必须说出来**——一份被悄悄截短的 diff 会让人以为改动就这么点。
        let more: Int
        let since: Date

        var verb: String { localized("activity.tool.\(tool)", fallback: tool) }
        var symbol: String { Session.symbol(tool: tool) }
    }

    /// 工具的图标。SF Symbols，不进本地化资源——图标不是文案。
    static func symbol(tool: String) -> String {
        switch tool {
        case "Read": return "doc.text"
        case "Edit", "NotebookEdit": return "pencil.line"
        case "Write": return "square.and.pencil"
        case "Bash": return "terminal"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return "circle.dashed"
        }
    }

    /// 当前状况那一行的图标。等待的四档各给各的：那一眼要读出「在等什么」，
    /// 而不只是「在等」。
    var symbol: String {
        switch salience {
        case .working:
            return tool.map(Session.symbol(tool:)) ?? "ellipsis"
        case .waiting(let waiting):
            switch waiting {
            case .question: return "questionmark.bubble"
            case .permission: return "lock"
            case .plan: return "doc.text.magnifyingglass"
            case .input: return "keyboard"
            }
        case .finished(let outcome):
            switch outcome {
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .quota: return "clock.badge.exclamationmark"
            }
        }
    }

    /// 当前这一行的两栏，与历史那几行用同一套排布。
    var stateParts: (verb: String, object: String?) {
        switch salience {
        case .working:
            guard let tool else { return (localized("activity.thinking"), nil) }
            return (localized("activity.tool.\(tool)", fallback: tool), object)
        case .waiting(let waiting):
            return (waiting.text, nil)
        case .finished(let outcome):
            return (outcome.text, label)
        }
    }

    /// 历史那几行。
    ///
    /// 在跑、且这一步带着工具时，**最后一步就是当前那一行**——它已经在下面单独占一行了，
    /// 这里再列一遍就成了两条一模一样的记录（实测撞到过）。
    var history: [Step] {
        if case .working = salience, tool != nil { return steps.dropLast() }
        return steps
    }

    /// 当前那一行的对象与量化结果。
    ///
    /// 在跑、且这一步带着工具时给**完整的那一份**——命令全文正是此刻要判断的东西。
    /// 正在生成时它没有对象：那时把上一步残留的命令摆在这里，等于说它还在跑那条命令。
    var stateDetail: (object: String?, metric: String?) {
        guard case .working = salience, tool != nil, let last = steps.last else {
            return (stateParts.object, nil)
        }
        return (last.detail ?? stateParts.object, last.metric)
    }

    /// 时间线上那个点的颜色。
    var tint: Color {
        switch salience {
        case .working: return .secondary
        case .waiting: return .accentColor
        case .finished(let outcome): return outcome.tint
        }
    }

    var salience: Salience
    /// 这条会话在干**哪件事**，取自用户自己那句提示词。
    ///
    /// 它是格子上第一行的字，也是这条会话的名字。不用 cwd 目录名：目录名回答的是
    /// 「哪个项目」，而同一个项目里同时会有好几件事在跑，你要找的是事。
    var task: String?
    /// 此刻在调用哪个工具，以及作用在什么上。
    ///
    /// **上报端不渲染文字**，只送这两样：界面文案统一走本地化资源，而 `dockctl` 不带
    /// 资源包，让它拼好一句中文送过来，等于把界面文字散到条外面去。
    var tool: String?
    var object: String?
    /// 与三档正交：在跑的同时可以有确定进度。nil = 边缘只呼吸，不画环。
    var progress: Double?
    /// 文本层的字，**只给常驻型状态**（歌名一类）。等待态与终态的文字走胶囊，不进格子：
    /// 那两档本来就浮着一个高显著度的东西，在格子里重复一遍既冗余，又会为了容纳文字
    /// 改变格子宽度——而格子一变宽就推挤邻格，那正是身份层要保的东西。
    var label: String?
    /// 只在 hover 里出现的细节：耗时、ETA、任务 n/m。**永远不进格子**（进度口径见设计文档 §3）。
    var detail: String?
    /// 用户这一轮说的话。任务名是这件事叫什么，它是这件事怎么被交代的。
    var prompt: String?
    /// 最后一段回复。**终态时面板贴出它，并且不再列历史**——那时你要的是结论，
    /// 不是经过；经过在你想看的时候还在终端里。
    var response: String?
    /// 哪个 agent。多个 agent 同时在跑时，光看格子分不出是谁。
    var agent: String?
    /// 正等着你批的那次授权。它不随上报来去，生命周期由那条连接决定
    /// （见 `AskServer`），因此不在 `push` 里赋值，由 `display` 挂上来。
    var ask: Ask?
    /// 近期走过的几步，旧的在前。只留末尾几条：面板要的是「刚才发生了什么」，
    /// 不是一份完整日志——完整的在终端里。
    var steps: [Step] = []
    /// 这一轮总共走了几步。`steps` 只留末尾几条，面板要报出总数才知道省略了多少。
    var turnSteps = 0
    /// 这条会话第一次上报的时刻。
    var started = Date()
    /// **这一轮**是什么时候开始的：用户提交提示词那一刻。
    ///
    /// 面板报的是本轮用时，不是会话总时长。会话可以开着一整天，那个数字不回答任何问题；
    /// 而「这一轮跑了多久」正是你盯着它时想知道的。
    var turnStarted = Date()
    /// 这一档是什么时候开始的。**跨同档的上报保持不变**（见 `SessionCenter`），
    /// 因此「等了多久」是它真正的含义。多个等待按它先来后到排队。
    var since = Date()
    /// 最后一次收到上报的时刻。
    var updated = Date()

    /// 此刻在做什么，渲染成一句话。nil = 上报没说，由 `stateLine` 退回「生成中」。
    ///
    /// 认不出的工具直接显示它的原名。给一个泛化的说法（「处理中」一类）等于把
    /// 「这一步在干什么」这个唯一要答的问题答成废话，而工具原名至少是真的。
    var action: String? {
        guard let tool else { return nil }
        let verb = localized("activity.tool.\(tool)", fallback: tool)
        guard let object, !object.isEmpty else { return verb }
        return localized("activity.action.format", verb, object)
    }

    /// 格子上第二行的字：此刻是什么状况。第一行是 `task`。
    var stateLine: String {
        switch salience {
        case .working:
            return action ?? localized("activity.thinking")
        case .waiting(let waiting):
            return waiting.text
        case .finished(let outcome):
            return "\(outcome.mark) \(label ?? outcome.text)"
        }
    }

    /// 终态是「未读」的：要用户看见过才退场。
    var isUnread: Bool {
        if case .finished = salience { return true }
        return false
    }

    var rank: Int { salience.rank }

    /// 同一格上，这一条是不是该盖过那一条。
    ///
    /// 同档的比法要分开：**等待按先来后到**——等得最久的那条最该先被理会；
    /// **在跑与终态按最近更新**——同档一律先来后到的话，一条陈旧的会话会把同一格上
    /// 一条正在活动的会话永久遮住，而它自己再也不会更新（实测撞到过）。
    func outranks(_ other: Session) -> Bool {
        guard rank == other.rank else { return rank < other.rank }
        if case .waiting = salience {
            // 待授权先于其余等待。它是唯一能在条上**当场办掉**的一档，其余等待只是陈述；
            // 把它压在下面，用户就没有地方按那一下，而对面还阻塞着等这个答复。
            if (ask != nil) != (other.ask != nil) { return ask != nil }
            return since < other.since
        }
        return updated > other.updated
    }

    /// 悬停提示。没有任何文字时不显示提示，而不是显示一句空话。
    var summary: String? {
        let percent = progress.map { "\(Int(($0 * 100).rounded()))%" }
        let all = [stateLine, detail, percent].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: " · ")
    }
}
