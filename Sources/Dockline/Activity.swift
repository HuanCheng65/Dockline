import AppKit
import DocklineCore

/// 活动挂在条上的哪一格。
///
/// 上报方给不出这个答案：它知道自己的 cwd 与祖先进程，不知道自己住在哪扇窗口里。
/// 由 `SessionBinding` 从这两样推断，推不出来就退回 `.app`——那是 App 在条上的第一格，
/// 与未读角标同一条规则。
enum StatusTarget: Hashable {
    case app(pid_t)
    case window(CGWindowID)
}

/// 一格上的活动状态（计划书 §3、实时状态设计 §2–§3）。
///
/// **显著度只有三档，由「此刻谁在等谁」决定，不由状态种类决定。** 状态的种类以后还会加
/// （限额、下载、播放…），显著度不能跟着加——否则条上会同时出现数件争抢注意力的东西，
/// 而这个功能的本职是注意力路由：任务运行期间不打扰用户，需要用户的那一刻精确唤回。
struct Activity: Equatable {
    /// 在等什么。**只有这一档允许高显著度。**
    enum Waiting: String, Equatable {
        case question, permission, plan, input

        /// 胶囊上那一个词。四档取同一个「待」字起头：它们是并列的等待，
        /// 差别只在等什么，句式一致才读得快。
        var text: String {
            switch self {
            case .question: return "待回答"
            case .permission: return "待授权"
            case .plan: return "待审阅"
            case .input: return "待输入"
            }
        }
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
        var text: String {
            switch self {
            case .done: return "已完成"
            case .failed: return "已失败"
            case .quota: return "已限额"
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
    }

    var salience: Salience
    /// 与三档正交：在跑的同时可以有确定进度。nil = 边缘只呼吸，不画环。
    var progress: Double?
    /// 文本层的字，**只给常驻型状态**（歌名一类）。等待态与终态的文字走胶囊，不进格子：
    /// 那两档本来就浮着一个高显著度的东西，在格子里重复一遍既冗余，又会为了容纳文字
    /// 改变格子宽度——而格子一变宽就推挤邻格，那正是身份层要保的东西。
    var label: String?
    /// 只在 hover 里出现的细节：耗时、ETA、任务 n/m。**永远不进格子**（进度口径见设计文档 §3）。
    var detail: String?
    /// 这一条是什么时候来的。同屏只弹一个胶囊，多个等待按先来后到排队，靠它定次序。
    var since = Date()

    /// 要不要浮出胶囊。working 不浮：它唯一需要传达的是任务仍在运行，
    /// 而文字诱导阅读，阅读即打断。
    var showsCapsule: Bool {
        switch salience {
        case .working: return false
        case .waiting, .finished: return true
        }
    }

    /// 胶囊里的那一行。终态带一句摘要，等待态一个词说明等什么。
    var capsuleText: String? {
        switch salience {
        case .working:
            return nil
        case .waiting(let waiting):
            return label.map { "\(waiting.text) · \($0)" } ?? waiting.text
        case .finished(let outcome):
            return "\(outcome.mark) \(label ?? outcome.text)"
        }
    }

    /// 终态是「未读」的：要用户看见过才退场。
    var isUnread: Bool {
        if case .finished = salience { return true }
        return false
    }

    /// 一格上撞了好几条上报时谁露面，以及同屏那一个胶囊归谁。数越小越优先。
    /// 等待排在最前——它是唯一允许高显著度的状态。
    var rank: Int {
        switch salience {
        case .waiting: return 0
        case .finished: return 1
        case .working: return 2
        }
    }

    /// 同一格上，这一条是不是该盖过那一条。同档按先来后到。
    func outranks(_ other: Activity) -> Bool {
        rank == other.rank ? since < other.since : rank < other.rank
    }

    /// 悬停提示。没有任何文字时不显示提示，而不是显示一句空话。
    var summary: String? {
        let percent = progress.map { "\(Int(($0 * 100).rounded()))%" }
        let all = [capsuleText ?? label, detail, percent].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: " · ")
    }
}

/// 活动状态的接收端。计划书 §3 的三层来源中，这里是自定义层：
/// 用户脚本通过 `dockctl` 上报，走分布式通知。
///
/// **上报方的身份与它显示在哪一格是两件事**（见 `ReportKey`）：这里存的是前者，落到
/// 哪一格由 `bind` 推断，推断结果连同当时的 cwd 一起记在这条上报上。cwd 没变、绑着的
/// 窗口还在，就不重算——复核因此只发生在会话头一次上报、cwd 变了、绑着的窗口没了这
/// 三种时候，而不会在任务结束那一刻拿当时的焦点去改口。那一刻用户多半已经在看别处，
/// 而「开始时在看、结束时不在看」正是这个功能存在的理由。
///
/// 活动一直保留到 `dockctl end`、宿主 App 退出、或（终态）被用户看见。**不设超时**——
/// 「多久算没动静」只有上报方知道，替它猜只会让长任务的指示器中途消失。
final class ActivityCenter {
    static let channel = "dev.starrydream.Dockline.activity"

    struct Report {
        var activity: Activity
        /// 上报方所在的 App。宿主退出时靠它把整批撤下。
        var host: pid_t
        /// 推断这次绑定时用的 cwd。它一变就作废重算。
        var cwd: String?
        var target: StatusTarget
    }

    private(set) var reports: [ReportKey: Report] = [:]
    var onChange: (() -> Void)?

    /// 把一条上报落到条上的哪一格。由 World 提供——窗口与焦点在它手上。
    /// `keeping` 是这条上报上次绑到的地方；它若仍然成立，实现方原样返回并把 why 留空。
    var bind: ((_ host: pid_t, _ cwd: String?, _ keeping: StatusTarget?)
        -> SessionBinding.Outcome)?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.channel), object: nil, queue: .main
        ) { [weak self] note in
            self?.receive(note.userInfo)
        }
    }

    /// 条上每一格该显示哪一条。多条上报落在同一格时按 `Activity.outranks` 取一条；
    /// 其余的该在 hover 卡里排队，那一段尚未实现。
    var display: [StatusTarget: Activity] {
        var result: [StatusTarget: Activity] = [:]
        for report in reports.values {
            guard let seated = result[report.target] else {
                result[report.target] = report.activity
                continue
            }
            if report.activity.outranks(seated) { result[report.target] = report.activity }
        }
        return result
    }

    /// 宿主 App 退出后，它名下的活动一并撤下。
    func remove(pid: pid_t) {
        let before = reports.count
        reports = reports.filter { $0.value.host != pid }
        guard reports.count != before else { return }
        onChange?()
    }

    /// 终态已被用户看见。未读语义的出口——只撤终态，等待中与运行中的不动。
    func markSeen(_ target: StatusTarget) {
        let before = reports.count
        reports = reports.filter { !($0.value.target == target && $0.value.activity.isUnread) }
        guard reports.count != before else { return }
        onChange?()
    }

    private func receive(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo, let command = userInfo["command"] as? String,
              let host = (userInfo["pid"] as? Int).map(pid_t.init),
              let key = Self.key(userInfo, host: host) else {
            Timeline.log("⚠️ 收到格式不符的活动上报：\(userInfo ?? [:])")
            return
        }
        switch command {
        case "end":
            guard reports.removeValue(forKey: key) != nil else { return }
            onChange?()
        case "push":
            guard let salience = Self.salience(userInfo) else { return }
            let cwd = userInfo["cwd"] as? String
            let activity = Activity(salience: salience,
                                    progress: userInfo["progress"] as? Double,
                                    label: userInfo["label"] as? String,
                                    detail: userInfo["detail"] as? String)
            let target = seat(key, host: host, cwd: cwd,
                              named: (userInfo["window"] as? Int).map(CGWindowID.init))
            reports[key] = Report(activity: activity, host: host, cwd: cwd, target: target)
            onChange?()
        default:
            Timeline.log("⚠️ 无法识别的活动指令「\(command)」")
        }
    }

    /// 这条上报该落在哪一格。上报方指名了窗口就照办，其余交给推断。
    private func seat(_ key: ReportKey, host: pid_t, cwd: String?,
                      named: CGWindowID?) -> StatusTarget {
        if let named { return .window(named) }
        guard let bind else { return .app(host) }
        // cwd 变了就不沿用：会话换了工作目录，它多半也换了窗口。
        let previous = reports[key]
        let keeping = previous?.cwd == cwd ? previous?.target : nil
        let outcome = bind(host, cwd, keeping)
        if let why = outcome.why { Timeline.log("活动绑定  \(key) → \(outcome.target)：\(why)") }
        return outcome.target
    }

    /// 上报方的身份。会话标识最准，其次是指名的窗口，都没有就整个 App 一条——
    /// 那意味着同一个 App 里的两个终端标签页会互相覆盖，正是会话标识存在的理由。
    private static func key(_ userInfo: [AnyHashable: Any], host: pid_t) -> ReportKey? {
        if let session = userInfo["session"] as? String, !session.isEmpty {
            return .session(session)
        }
        if let wid = userInfo["window"] as? Int { return .window(CGWindowID(wid)) }
        return .host(host)
    }

    private static func salience(_ userInfo: [AnyHashable: Any]) -> Activity.Salience? {
        switch userInfo["state"] as? String {
        case "working":
            return .working
        case "waiting":
            guard let raw = userInfo["reason"] as? String,
                  let reason = Activity.Waiting(rawValue: raw) else {
                Timeline.log("⚠️ waiting 缺少有效的 reason：\(userInfo)")
                return nil
            }
            return .waiting(reason)
        case "finished":
            guard let raw = userInfo["outcome"] as? String,
                  let outcome = Activity.Outcome(rawValue: raw) else {
                Timeline.log("⚠️ finished 缺少有效的 outcome：\(userInfo)")
                return nil
            }
            return .finished(outcome)
        case let other:
            Timeline.log("⚠️ 无法识别的活动状态「\(other ?? "—")」")
            return nil
        }
    }
}
