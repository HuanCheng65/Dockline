import AppKit

/// 上报通道（实时状态设计 §4.1）。
///
/// 分布式通知：本机同一登录会话内的 IPC 总线，无需常驻连接、无需约定路径，收发双方
/// 都不需要额外基础设施。活动一直显示到 `end`、宿主 App 退出、或（终态）被用户看见
/// ——不设超时，因为「多久算没动静」只有上报方知道。
enum Report {
    static let channel = "dev.starrydream.Dockline.activity"

    static func post(_ payload: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(channel), object: nil, userInfo: payload, deliverImmediately: true)
    }

    /// 上报者是脚本，脚本自己不在 bar 上。往上找第一个有 bundle ID 的祖先进程，
    /// 那才是 bar 上那一格——在终端里跑就是终端，在 VS Code 的集成终端里跑就是 VS Code。
    static func hostApp() -> pid_t {
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

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
