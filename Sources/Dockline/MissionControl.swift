import AppKit
import DocklineCore

/// 调度中心的进出。
///
/// 系统不广播这件事。实测过的路全是死的：工作区通知（含 Space 变化）、分布式通知、
/// 前台 App 与菜单栏归属在进出 MC 时一律不动；程序坞的 AX 树只在**退出**时给一条
/// `AXUIElementDestroyed`，进入毫无动静，且窗口类通知一律报 -25207 不支持；四指上滑
/// 是手势，不产生我们看得到的 CGEvent。
///
/// 唯一完备的事件源是窗口服务器自己的通知：**进入发 1327、退出发 1328**（每块屏各一次）。
/// 事件号由实测确定，不是照抄社区常量——`open -a "Mission Control"` 两轮进出完全复现，
/// 而同批候选里的 1507 / 1508 连开个计算器都会响，是通用噪声。
///
/// 判据只用事件，不再回查窗口列表：1327 比程序坞的 MC 窗口真正上屏早约 30ms，
/// 那一刻查窗口列表还查不到。
final class MissionControlWatch {
    private static let enter: UInt32 = 1327
    private static let leave: UInt32 = 1328

    /// true = 进了调度中心
    var onChange: ((Bool) -> Void)?

    func start() {
        // 回调是 C 函数指针，捕获不了任何东西，自身指针只能经上下文传进去。
        // 观察者与 App 同生命周期，不必考虑注销（SkyLight 也没给注销的口子）。
        let proc: SkyLight.NotifyProc = { type, _, _, context in
            guard let context else { return }
            let watch = Unmanaged<MissionControlWatch>.fromOpaque(context).takeUnretainedValue()
            let active = type == MissionControlWatch.enter
            DispatchQueue.main.async { watch.onChange?(active) }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard SkyLight.onEvent(Self.enter, context: context, proc),
              SkyLight.onEvent(Self.leave, context: context, proc)
        else {
            Timeline.log("⚠️ SLSRegisterNotifyProc 不可用，调度中心让位关闭")
            return
        }
    }
}
