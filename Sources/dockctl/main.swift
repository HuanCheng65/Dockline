import AppKit

// dockctl —— 活动状态的上报入口（计划书 §3「活动状态」的自定义层）。
//
//   dockctl push [--progress 0.7] [--label 编译] [--eta 40m] [--pid 1234]
//   dockctl end  [--pid 1234]
//
// 通道用分布式通知：无需常驻连接、无需约定路径，收发双方都不需要额外基础设施。
// 上报的活动一直显示到 `end`，或到宿主 App 退出为止——不设超时，
// 因为「多久算没动静」只有上报方知道。

let channel = "dev.starrydream.Dockline.activity"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("dockctl: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// 上报者是脚本，脚本自己不在 bar 上。往上找第一个有 bundle ID 的祖先进程，
/// 那才是 bar 上那一格——在终端里跑就是终端。
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
    fail("找不到上报目标：当前进程的祖先里没有 App。可用 --pid 显式指定。")
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command == "push" || command == "end" else {
    fail("用法：dockctl push [--progress 0-1] [--label 文本] [--eta 文本] [--pid 进程号]\n"
         + "      dockctl end [--pid 进程号]")
}
arguments.removeFirst()

var progress: Double?
var label: String?
var eta: String?
var pid: pid_t?

while let flag = arguments.first {
    arguments.removeFirst()
    guard let value = arguments.first else { fail("\(flag) 缺少取值") }
    arguments.removeFirst()
    switch flag {
    case "--progress":
        guard let number = Double(value), (0...1).contains(number) else {
            fail("--progress 需要 0 到 1 之间的数值，收到「\(value)」")
        }
        progress = number
    case "--label": label = value
    case "--eta": eta = value
    case "--pid":
        guard let number = pid_t(value) else { fail("--pid 需要进程号，收到「\(value)」") }
        pid = number
    default:
        fail("无法识别的选项 \(flag)")
    }
}

var payload: [String: Any] = ["pid": Int(pid ?? hostApp()), "state": command]
if let progress { payload["progress"] = progress }
if let label { payload["label"] = label }
if let eta { payload["eta"] = eta }

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(channel), object: nil, userInfo: payload, deliverImmediately: true)
