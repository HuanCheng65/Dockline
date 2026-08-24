import AppKit

/// 一格上的活动状态（计划书 §3）。
struct Activity: Equatable {
    /// nil = 没有确定进度，格子边缘呼吸；有值则边缘走进度环
    var progress: Double?
    var label: String?
    var eta: String?

    /// 悬停提示。没有任何文字时不显示提示，而不是显示一句空话。
    var summary: String? {
        let parts = [label, eta].compactMap { $0 }
        let percent = progress.map { "\(Int(($0 * 100).rounded()))%" }
        let all = parts + [percent].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: " · ")
    }
}

/// 活动状态的接收端。计划书 §3 的三层来源中，这里是自定义层：
/// 用户脚本通过 `dockctl` 上报，走分布式通知。
///
/// 活动一直保留到 `dockctl end` 或宿主 App 退出。不设超时——
/// 「多久算没动静」只有上报方知道，替它猜只会让长任务的指示器中途消失。
final class ActivityCenter {
    static let channel = "dev.starrydream.Dockline.activity"

    private(set) var activities: [pid_t: Activity] = [:]
    var onChange: (() -> Void)?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.channel), object: nil, queue: .main
        ) { [weak self] note in
            self?.receive(note.userInfo)
        }
    }

    func remove(pid: pid_t) {
        guard activities.removeValue(forKey: pid) != nil else { return }
        onChange?()
    }

    private func receive(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo, let pid = userInfo["pid"] as? Int,
              let state = userInfo["state"] as? String else {
            Timeline.log("⚠️ 收到格式不符的活动上报：\(userInfo ?? [:])")
            return
        }
        switch state {
        case "end":
            remove(pid: pid_t(pid))
        case "push":
            activities[pid_t(pid)] = Activity(progress: userInfo["progress"] as? Double,
                                              label: userInfo["label"] as? String,
                                              eta: userInfo["eta"] as? String)
            onChange?()
        default:
            Timeline.log("⚠️ 无法识别的活动状态「\(state)」")
        }
    }
}
