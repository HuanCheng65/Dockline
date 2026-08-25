import AppKit
import DocklineCore

/// 调度中心的进出。
///
/// 系统不广播这件事。实测过的路全是死的：工作区通知（含 Space 变化）、分布式通知、
/// 前台 App 与菜单栏归属在进出 MC 时一律不动；程序坞的 AX 树只在**退出**时给一条
/// `AXUIElementDestroyed`，进入毫无动静，且窗口类通知一律报 -25207 不支持；四指上滑
/// 是手势，不产生我们看得到的 CGEvent。
///
/// 唯一够用的事件源是窗口服务器自己的通知：**1327 开始、1328 结束**。但它们不是
/// 「调度中心开 / 关」——那是最初只测了 MC 两轮进出得出的结论，漏掉了「还有谁也会响」。
/// 实测（2026-08）同一对信号在这些动作上一样发：
///   · 调度中心      1327→1328 相隔 2.8–3.3s
///   · 最小化 / 取消最小化  相隔 0.22s
///   · 拖放文件      相隔 3.3s，整个拖拽过程都挂着
/// 拖放那一条是有后果的：条在整个拖拽期间让位，于是文件根本拖不到 Dockline 上。
/// 时长也区分不开——拖放与真 MC 一样长。1327/1328 更像是「窗口服务器开始 / 结束了
/// 一次转场」，调度中心只是其中一种。
///
/// 所以判据从「信号说它开了」改成「看见它确实开着」：调度中心开着时，程序坞会在屏上
/// 摆一张铺满整屏、已上屏的 surface（实测 1327 之后 38–66ms 出现，转场结束即消失），
/// 而最小化与拖放在 600ms 内一张都没有。收到 1327 先不让位，确认到那张 surface 才让。
final class MissionControlWatch {
    private static let enter: UInt32 = 1327
    private static let leave: UInt32 = 1328

    /// 确认窗口。实测 38–66ms，取约五倍余量；确认期间每 30ms 查一次。
    /// 单次查询实测 0.53ms（只列在屏窗口），整段确认不到 5ms，且只在转场时发生。
    private static let confirmWindow: TimeInterval = 0.3
    private static let confirmInterval: TimeInterval = 0.03

    /// true = 进了调度中心
    var onChange: ((Bool) -> Void)?

    private var confirming: DispatchWorkItem?
    private var active = false

    func start() {
        // 回调是 C 函数指针，捕获不了任何东西，自身指针只能经上下文传进去。
        // 观察者与 App 同生命周期，不必考虑注销（SkyLight 也没给注销的口子）。
        let proc: SkyLight.NotifyProc = { type, _, _, context in
            guard let context else { return }
            let watch = Unmanaged<MissionControlWatch>.fromOpaque(context).takeUnretainedValue()
            let entering = type == MissionControlWatch.enter
            DispatchQueue.main.async {
                entering ? watch.transitionBegan() : watch.transitionEnded()
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard SkyLight.onEvent(Self.enter, context: context, proc),
              SkyLight.onEvent(Self.leave, context: context, proc)
        else {
            Timeline.log("⚠️ SLSRegisterNotifyProc 不可用，调度中心让位关闭")
            return
        }
    }

    private func transitionBegan() {
        confirming?.cancel()
        confirm(until: Date().addingTimeInterval(Self.confirmWindow))
    }

    private func transitionEnded() {
        confirming?.cancel()
        confirming = nil
        guard active else { return }
        active = false
        onChange?(false)
    }

    /// 转场开始了，但还不知道是不是调度中心。查到那张 surface 就让位，查不到就作罢。
    private func confirm(until deadline: Date) {
        if Self.missionControlIsUp() {
            confirming = nil
            guard !active else { return }
            active = true
            onChange?(true)
            return
        }
        guard Date() < deadline else {
            confirming = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.confirm(until: deadline) }
        confirming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmInterval, execute: work)
    }

    /// 屏上有没有程序坞那张铺满整屏的 surface。
    ///
    /// 只列在屏窗口，不走索引那份 `.optionAll`：程序坞平时还挂着一张同样铺满屏、
    /// 但 ordered-out 的 surface，全量列表里它一直在，判据会恒为真。
    /// 按 pid 认程序坞——`ownerName` 是本地化的（中文系统上是「程序坞」）。
    private static func missionControlIsUp() -> Bool {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else { return false }
        let screens = NSScreen.screens.map { flipY($0.frame) }
        return enumerateOnScreenWindowsFrontToBack().contains { window in
            window.pid == dock && screens.contains { screen in
                window.bounds.width >= screen.width - 1 && window.bounds.height >= screen.height - 1
            }
        }
    }
}
