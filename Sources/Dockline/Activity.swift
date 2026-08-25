import AppKit
import DocklineCore

/// 活动挂在谁身上。
///
/// 现在只有 `dockctl` 一个来源，它按祖先进程链找到宿主 App，产出的几乎都是 `.app`；
/// `.window` 这一支要等会话与窗口的绑定做出来才会有真实来源（见实时状态设计 §4.3），
/// 但模型两支都收，届时不必改结构。
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
/// 活动一直保留到 `dockctl end`、宿主 App 退出、或（终态）被用户看见。**不设超时**——
/// 「多久算没动静」只有上报方知道，替它猜只会让长任务的指示器中途消失。
final class ActivityCenter {
    static let channel = "dev.starrydream.Dockline.activity"

    private(set) var activities: [StatusTarget: Activity] = [:]
    var onChange: (() -> Void)?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.channel), object: nil, queue: .main
        ) { [weak self] note in
            self?.receive(note.userInfo)
        }
    }

    /// 宿主 App 退出后，它名下的活动一并撤下。窗口那一支同样撤下：绑在那些窗口上的
    /// 会话运行在同一个进程内。
    func remove(pid: pid_t, windows: Set<CGWindowID>) {
        let before = activities.count
        activities = activities.filter { target, _ in
            switch target {
            case .app(let owner): return owner != pid
            case .window(let id): return !windows.contains(id)
            }
        }
        guard activities.count != before else { return }
        onChange?()
    }

    /// 终态已被用户看见。未读语义的出口——只撤终态，等待中与运行中的不动。
    func markSeen(_ target: StatusTarget) {
        guard let activity = activities[target], activity.isUnread else { return }
        activities[target] = nil
        onChange?()
    }

    private func receive(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo, let command = userInfo["command"] as? String,
              let target = Self.target(userInfo) else {
            Timeline.log("⚠️ 收到格式不符的活动上报：\(userInfo ?? [:])")
            return
        }
        switch command {
        case "end":
            guard activities.removeValue(forKey: target) != nil else { return }
            onChange?()
        case "push":
            guard let salience = Self.salience(userInfo) else { return }
            activities[target] = Activity(salience: salience,
                                          progress: userInfo["progress"] as? Double,
                                          label: userInfo["label"] as? String,
                                          detail: userInfo["detail"] as? String)
            onChange?()
        default:
            Timeline.log("⚠️ 无法识别的活动指令「\(command)」")
        }
    }

    private static func target(_ userInfo: [AnyHashable: Any]) -> StatusTarget? {
        if let wid = userInfo["window"] as? Int { return .window(CGWindowID(wid)) }
        if let pid = userInfo["pid"] as? Int { return .app(pid_t(pid)) }
        return nil
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
