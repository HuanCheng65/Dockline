import AppKit

/// 手写的那三个动词：`push` / `event` / `end`。
///
/// 它们对应模型里的三件事，不是同一件事的三种写法：`push` 是**持续状态**（在跑、在等你），
/// `event` 是**一次性事件**（停了），它走未读语义、停留到被看见为止，`end` 是撤下。
/// 把终态挤进 push 表达不出这条界线——那正是第一版协议的缺口。
enum Push {
    static func run(_ command: String, _ arguments: [String]) -> Never {
        var arguments = arguments
        var state: String?
        var reason: String?
        var outcome: String?
        var progress: Double?
        var label: String?
        var detail: String?
        var pid: pid_t?
        var window: CGWindowID?
        var session: String?
        var cwd = FileManager.default.currentDirectoryPath

        while let flag = arguments.first {
            arguments.removeFirst()
            guard let value = arguments.first else { fail("\(flag) 缺少取值") }
            arguments.removeFirst()
            switch flag {
            case "--state":
                guard ["working", "waiting"].contains(value) else {
                    fail("--state 只能是 working 或 waiting，收到「\(value)」；终态请使用 dockctl event")
                }
                state = value
            case "--reason":
                guard ["question", "permission", "plan", "input"].contains(value) else {
                    fail("--reason 只能是 question / permission / plan / input，收到「\(value)」")
                }
                reason = value
            case "--kind":
                guard ["done", "failed", "quota"].contains(value) else {
                    fail("--kind 只能是 done / failed / quota，收到「\(value)」")
                }
                outcome = value
            case "--progress":
                guard let number = Double(value), (0...1).contains(number) else {
                    fail("--progress 需要 0 到 1 之间的数值，收到「\(value)」")
                }
                progress = number
            case "--label": label = value
            case "--detail": detail = value
            case "--pid":
                guard let number = pid_t(value) else { fail("--pid 需要进程号，收到「\(value)」") }
                pid = number
            case "--window":
                guard let number = CGWindowID(value) else {
                    fail("--window 需要窗口号，收到「\(value)」")
                }
                window = number
            case "--session":
                guard !value.isEmpty else { fail("--session 不能为空") }
                session = value
            case "--cwd":
                guard !value.isEmpty else { fail("--cwd 不能为空") }
                cwd = value
            default:
                fail("无法识别的选项 \(flag)")
            }
        }

        // 宿主 pid 任何情况下都要带上：条上要靠它在宿主退出时把这个 App 名下的活动整批
        // 撤下，推断落点时也要靠它圈出候选窗口。--window 是在它之上直接指定落点，
        // 不是替代它。
        var payload: [String: Any] = [
            "command": command == "end" ? "end" : "push",
            "pid": Int(pid ?? Report.hostApp()),
            "cwd": cwd,
        ]
        if let window { payload["window"] = Int(window) }
        if let session { payload["session"] = session }

        switch command {
        case "push":
            guard let state else { fail("push 需要 --state") }
            payload["state"] = state
            if state == "waiting" {
                guard let reason else { fail("--state waiting 需要 --reason 指明等待类型") }
                payload["reason"] = reason
            }
        case "event":
            guard let outcome else { fail("event 需要 --kind") }
            payload["state"] = "finished"
            payload["outcome"] = outcome
        default:
            break
        }

        if let progress { payload["progress"] = progress }
        if let label { payload["label"] = label }
        if let detail { payload["detail"] = detail }

        Report.post(payload)
        exit(0)
    }
}
