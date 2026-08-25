import AppKit

// dockctl —— 活动状态的上报入口（计划书 §3「活动状态」的自定义层）。
//
//   dockctl push  --state working|waiting [--reason question|permission|plan|input]
//                 [--progress 0-1] [--label 文本] [--detail 文本] [--pid N | --window N]
//   dockctl event --kind done|failed|quota [--label 摘要] [--detail 文本] [--pid N | --window N]
//   dockctl end   [--pid N | --window N]
//
// 三个动词对应模型里的三件事，不是同一件事的三种写法：`push` 是**持续状态**（在跑、在等你），
// `event` 是**一次性事件**（停了），它走未读语义、停留到被看见为止，`end` 是撤下。
// 把终态挤进 push 表达不出这条界线——那正是第一版协议的缺口。
//
// 通道用分布式通知：无需常驻连接、无需约定路径，收发双方都不需要额外基础设施。
// 活动一直显示到 `end`、宿主 App 退出、或（终态）被用户看见——不设超时，
// 因为「多久算没动静」只有上报方知道。

let channel = "dev.starrydream.Dockline.activity"

let usage = """
用法：dockctl push  --state working|waiting [--reason question|permission|plan|input]
                    [--progress 0-1] [--label 文本] [--detail 文本] [共用选项]
      dockctl event --kind done|failed|quota [--label 摘要] [--detail 文本] [共用选项]
      dockctl end   [共用选项]
      dockctl hook  从 stdin 读 Claude Code 的 hook 事件 JSON，自行翻成上报
      dockctl install-hooks    把上一条登记进 ~/.claude/settings.json
      dockctl uninstall-hooks  撤销登记

共用选项：
  --session 标识   上报方的会话标识。同一个 App 里的多个会话靠它区分；
                   缺省时整个 App 共用一条，两个终端标签页会互相覆盖。
  --cwd 路径       用来推断这个会话住在哪扇窗口里。缺省取当前工作目录。
  --pid 进程号     宿主 App。缺省沿祖先进程链找到第一个 App。
  --window 窗口号  直接指定落在哪扇窗口上，跳过推断。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("dockctl: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// 上报者是脚本，脚本自己不在 bar 上。往上找第一个有 bundle ID 的祖先进程，
/// 那才是 bar 上那一格——在终端里跑就是终端，在 VS Code 的集成终端里跑就是 VS Code。
func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let parent = info.kp_eproc.e_ppid
    return parent > 0 ? parent : nil
}

func hostApp() -> pid_t {
    var current = getppid()
    for _ in 0..<16 {
        if NSRunningApplication(processIdentifier: current)?.bundleIdentifier != nil {
            return current
        }
        guard let parent = parentPID(of: current), parent != current else { break }
        current = parent
    }
    fail("无法确定上报目标：当前进程的祖先进程中没有 App。请以 --pid 指定。")
}

func post(_ payload: [String: Any]) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(channel), object: nil, userInfo: payload, deliverImmediately: true)
}

/// Claude Code 的 hook 入口：事件 JSON 从 stdin 来，翻译见 `HookAdapter`。
///
/// **不许往 stdout 写任何东西**——hook 的 stdout 是它与 Claude Code 之间的通道，
/// 状态上报没有资格在那上面说话。出错走 stderr 加非零退出：那是非阻塞的错误，
/// 看得见，又不会把用户的 agent 拦下来。
func runHook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
        fail("hook 的输入不是 JSON 对象")
    }
    guard var payload = HookAdapter.payload(json) else { exit(0) }
    guard let session = json["session_id"] as? String, !session.isEmpty else {
        fail("hook 事件缺少 session_id")
    }
    payload["session"] = session
    payload["pid"] = Int(hostApp())
    // cwd 以事件里那份为准：hook 进程的工作目录未必是会话的。
    if let cwd = json["cwd"] as? String { payload["cwd"] = cwd }
    // 每个事件都重算一次会话名，不只在提交提示词那一次：会话标题会随对话变，
    // 而它就是格子第一行的字。
    if payload["command"] as? String == "push", let task = HookAdapter.task(json) {
        payload["task"] = task
    }
    post(payload)
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first,
      ["push", "event", "end", "hook", "install-hooks", "uninstall-hooks"].contains(command)
else { fail(usage) }
if command == "hook" { runHook() }
if command == "install-hooks" || command == "uninstall-hooks" {
    var settings: String?
    if let index = arguments.firstIndex(of: "--settings") {
        guard index + 1 < arguments.count else { fail("--settings 缺少路径") }
        settings = arguments[index + 1]
    }
    print(HookInstaller.run(uninstall: command == "uninstall-hooks", settings: settings))
    exit(0)
}
arguments.removeFirst()

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
        guard let number = CGWindowID(value) else { fail("--window 需要窗口号，收到「\(value)」") }
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

// 宿主 pid 任何情况下都要带上：条上要靠它在宿主退出时把这个 App 名下的活动整批撤下，
// 推断落点时也要靠它圈出候选窗口。--window 是在它之上直接指定落点，不是替代它。
var payload: [String: Any] = [
    "command": command == "end" ? "end" : "push",
    "pid": Int(pid ?? hostApp()),
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

post(payload)
