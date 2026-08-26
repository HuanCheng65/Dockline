import AppKit
import DocklineCore
import SwiftUI

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
final class SessionCenter {
    static let channel = "dev.starrydream.Dockline.activity"

    struct Report {
        var session: Session
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

    /// 条上每一格该显示哪一条。多条上报落在同一格时按 `Session.outranks` 取一条；
    /// 其余的该在 hover 卡里排队，那一段尚未实现。
    ///
    /// 待授权要**先挂上再排序**：谁能当场办掉是排序的判据之一（见 `Session.outranks`），
    /// 排完再挂就晚了。同一条会话上撞了两次授权时只挂最早的那次，答掉它下一次才露面。
    var display: [StatusTarget: Session] {
        let asks = Dictionary(grouping: pending.values, by: \.key)
            .compactMapValues { $0.map(\.ask).min { $0.since < $1.since } }
        var result: [StatusTarget: Session] = [:]
        for (key, report) in reports {
            var session = report.session
            session.ask = asks[key]
            guard let seated = result[report.target] else {
                result[report.target] = session
                continue
            }
            if session.outranks(seated) { result[report.target] = session }
        }
        return result
    }

    // MARK: 就地授权（实时状态设计 §4.7）

    private struct Pending {
        let key: ReportKey
        let host: pid_t
        let ask: Session.Ask
    }

    private var pending: [UUID: Pending] = [:]

    /// 把答复送回去。由 `World` 接到 `AskServer` 上。
    var onAnswer: ((_ id: UUID, _ allow: Bool, _ message: String?) -> Void)?
    /// 不作决定，把这次授权交回 Claude Code 自己那套流程。
    var onDecline: ((UUID) -> Void)?

    /// 收到一次授权请求。
    ///
    /// 它同时是一条**等待态上报**：格子那一行要立刻说「待授权」，不能等六秒后
    /// Claude Code 自己那条通知过来。这里因此借道 `receive` 走一遍完整的上报路径——
    /// 会话名、提示词、落在哪一格的推断，与其余状态共用同一套，不另立一份。
    func receiveAsk(_ id: UUID, _ payload: [String: Any]) {
        guard let host = (payload["pid"] as? Int).map(pid_t.init),
              let key = Self.key(payload, host: host),
              let verb = (payload["verb"] as? String).map(Verb.init(name:)),
              let raw = payload["lines"] as? [[String]] else {
            Timeline.log("⚠️ 收到格式不符的授权请求，已交回 Claude Code 自行处理：\(payload)")
            onDecline?(id)
            return
        }
        var lines: [Session.Ask.Line] = []
        for (index, pair) in raw.enumerated() {
            guard pair.count == 2, let sign = Session.Ask.Line.Sign(rawValue: pair[0]) else {
                Timeline.log("⚠️ 授权请求里有读不懂的行「\(pair)」，已交回 Claude Code 自行处理")
                onDecline?(id)
                return
            }
            lines.append(Session.Ask.Line(id: index, sign: sign, text: pair[1]))
        }
        pending[id] = Pending(key: key, host: host,
                              ask: Session.Ask(id: id, verb: verb,
                                                object: payload["object"] as? String,
                                                lines: lines,
                                                more: payload["more"] as? Int ?? 0,
                                                since: Date()))
        var push: [String: Any] = ["command": "push", "state": "waiting", "reason": "permission",
                                   "pid": Int(host)]
        for field in ["session", "cwd", "task", "agent"] { push[field] = payload[field] }
        receive(push)
    }

    /// 用户在条上按了一下。
    func answer(_ id: UUID, allow: Bool) {
        guard pending.removeValue(forKey: id) != nil else { return }
        // 拒绝的理由会进模型的上下文。它是给人看的字，所以在这里取本地化资源，
        // 而不是让 dockctl 拼一句话送过来（见设计文档 §4 的界面文字一条）。
        onAnswer?(id, allow, allow ? nil : localized("activity.ask.denied"))
        onChange?()
    }

    /// 对面在拿到答复之前走了：hook 被超时杀掉、会话被中断、终端被关掉。
    func dropAsk(_ id: UUID) {
        guard pending.removeValue(forKey: id) != nil else { return }
        onChange?()
    }

    /// 宿主 App 退出后，它名下的活动一并撤下。
    func remove(pid: pid_t) {
        // 待授权也一并交回去。宿主没了，这条待授权在条上再没有落点，
        // 留着它就是一条谁也看不见、对面却还在等的请求。
        for (id, entry) in pending where entry.host == pid {
            pending[id] = nil
            onDecline?(id)
        }
        let before = reports.count
        reports = reports.filter { $0.value.host != pid }
        guard reports.count != before else { return }
        onChange?()
    }

    /// 终态已被用户看见。未读语义的出口——只撤终态，等待中与运行中的不动。
    func markSeen(_ target: StatusTarget) {
        let before = reports.count
        reports = reports.filter { !($0.value.target == target && $0.value.session.isUnread) }
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
            let previous = reports[key]?.session
            // 任务名是**粘的**：不是每个事件都带得出它，而那些事件同样要显示在这条
            // 会话名下。动作相反，每次都换——它说的是「此刻」。
            // `since` 同样粘住，但只在这一档没变的时候：它的含义是「这一档开始于何时」，
            // 等待队列按它排序，重置一次就等于插了一次队。
            let verb = (userInfo["verb"] as? String).map(Verb.init(name:))
            let object = userInfo["object"] as? String
            let step = verb.map {
                Session.Step(id: (previous?.steps.last?.id ?? 0) + 1, verb: $0, object: object,
                              detail: userInfo["detail"] as? String,
                              metric: userInfo["metric"] as? String)
            }
            // 用户提交提示词就是**新的一轮**。上一轮走过的步子、上一轮的结论都要退场：
            // 新提示词底下挂着上一轮的工具调用，读起来就像它正在做那件事（实测撞到过）。
            let turn = userInfo["turn"] as? Bool == true
            let carried = turn ? nil : previous
            let session = Session(salience: salience,
                                    task: userInfo["task"] as? String ?? previous?.task,
                                    verb: verb,
                                    object: object,
                                    progress: userInfo["progress"] as? Double,
                                    label: userInfo["label"] as? String,
                                    detail: userInfo["detail"] as? String,
                                    prompt: userInfo["prompt"] as? String ?? previous?.prompt,
                                    response: userInfo["response"] as? String,
                                    agent: userInfo["agent"] as? String ?? previous?.agent,
                                    steps: Self.appending(step, to: carried?.steps ?? []),
                                    turnSteps: (carried?.turnSteps ?? 0) + (step == nil ? 0 : 1),
                                    started: previous?.started ?? Date(),
                                    turnStarted: carried?.turnStarted ?? Date(),
                                    since: previous?.salience.rank == salience.rank
                                        ? previous?.since ?? Date() : Date())
            let target = seat(key, host: host, cwd: cwd,
                              named: (userInfo["window"] as? Int).map(CGWindowID.init))
            reports[key] = Report(session: session, host: host, cwd: cwd, target: target)
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

    /// 面板上留几步。留多了那份列表自己就成了要读的东西，而面板要答的是
    /// 「刚才发生了什么」；完整的经过在终端里。
    private static let stepLimit = 4

    /// 记下走过的这一步。没带工具的上报（提交提示词、工具跑完、等待、终态）不是一步，
    /// 原样带过——否则列表里会塞满没有内容的空行。
    private static func appending(_ step: Session.Step?,
                                  to steps: [Session.Step]) -> [Session.Step] {
        guard let step else { return steps }
        return Array((steps + [step]).suffix(stepLimit))
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

    private static func salience(_ userInfo: [AnyHashable: Any]) -> Session.Salience? {
        switch userInfo["state"] as? String {
        case "working":
            return .working
        case "waiting":
            guard let raw = userInfo["reason"] as? String,
                  let reason = Session.Waiting(rawValue: raw) else {
                Timeline.log("⚠️ waiting 缺少有效的 reason：\(userInfo)")
                return nil
            }
            return .waiting(reason)
        case "finished":
            guard let raw = userInfo["outcome"] as? String,
                  let outcome = Session.Outcome(rawValue: raw) else {
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
