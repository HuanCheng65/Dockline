import AppKit
import Carbon.HIToolbox
import DocklineCore

// MARK: - keytap（拦截式 event tap 的可行性）
//
// 计划书 §6 M6 的窗口级键盘切换要在修饰键按住期间**吞掉** Tab，这推翻了 §8 原有的
// 「event tap 仅保留观察用途」。实现之前先用这支探针把五件事问清楚：
//
//   ① 拦截式 tap 建不建得起来（本体 `FullscreenWatch` 只验过 `.listenOnly`）
//   ② 吞掉的 ⌥Tab 会不会仍旧漏给前台 App；连按时的自动重复收不收得到
//   ③ 松开 ⌥ 这一刻能否从 flagsChanged 稳定拿到
//   ④ `kCGEventTapDisabledByTimeout` 之后能不能自己救回来
//   ⑤ 回调本身贵不贵——它挂在每一次击键上，按 §2 的成本预算这是常驻税
//
// 与光标钳制那次失败（§8）不能互推：钳制失败在于光标真实位置由窗口服务器先算好，
// 属坐标路径的性质；键盘路径是另一回事，所以要单独实测。

/// Tab 的键码。
private let tabKey = Int64(kVK_Tab)

/// 探针的全部状态。tap 回调是 C 函数指针，捕获不了任何东西，自身指针经 refcon 传进去。
final class KeyTapProbe {
    /// 拦截用的主 tap
    private var tap: CFMachPort?
    /// 只读的下游探测 tap。见 `makeDetector`。
    private var detector: CFMachPort?

    /// 刚刚吞掉了一次 Tab 按下。抬起必须跟着吞——见 `handle` 里的说明。
    private var swallowingTab = false
    /// 上一次看到的 ⌥ 状态，用来认按下与松开这两个边沿。
    private var optionDown = false

    /// 直通事件的回调耗时（微秒）。热路径上不打印，只记数——打印本身就是被测的成本。
    private var costs: [Double] = []
    private var swallowedDown = 0
    private var swallowedUp = 0
    private var repeats = 0
    private var leaks = 0
    private var disables = 0

    /// 按 Esc 故意把回调卡住，逼系统停用 tap（问题 ④）。默认关。
    private let stalls: Bool
    private let start = Date()

    init(stalls: Bool) { self.stalls = stalls }

    private func note(_ message: String) {
        print(String(format: "%8.3fs  %@", Date().timeIntervalSince(start), message))
        fflush(stdout)
    }

    // MARK: 建立

    func start(seconds: Double) {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,        // ← 与 FullscreenWatch 的唯一区别：可以吞
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyTapProbe>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // 建不起来的原因只有两类：没权限，或系统不给拦截式。分清楚，别含混成一句失败。
            print("❌ 拦截式 tap 创建失败。AXIsProcessTrusted() = \(AXIsProcessTrusted())")
            print("   权限为真却仍失败，说明系统拒绝的是 .defaultTap 本身，问题 ① 即告否定。")
            exit(1)
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        detector = makeDetector()

        report(seconds: seconds)
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
        // event tap 经 CFRunLoop 源投递，裸 RunLoop 就够。`events` 命令那边必须起
        // NSApplication 是另一回事——窗口服务器的通知走连接自己的事件队列。
        RunLoop.main.run()
    }

    /// 下游探测 tap：挂在 annotated session 的队尾，也就是事件送进 App 之前的最后一站。
    /// 主 tap 吞掉的事件不该走到这里；它要是看见了 ⌥Tab，就是实打实漏了（问题 ②）。
    private func makeDetector() -> CFMachPort? {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let detector = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                Unmanaged<KeyTapProbe>.fromOpaque(refcon).takeUnretainedValue()
                    .inspectDownstream(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            print("⚠️ 下游探测 tap 建不起来，漏没漏只能靠肉眼看 TextEdit。")
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, detector, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: detector, enable: true)
        return detector
    }

    // MARK: 主回调

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let began = DispatchTime.now().uptimeNanoseconds

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            disables += 1
            let cause = type == .tapDisabledByTimeout ? "回调超时" : "用户输入"
            guard let tap else { return nil }
            CGEvent.tapEnable(tap: tap, enable: true)
            note("⚠️ 系统停用了 tap（\(cause)），已重新启用。再按一次 ⌥Tab 看还吞不吞。")
            return nil

        case .flagsChanged:
            let down = event.flags.contains(.maskAlternate)
            let edge = down != optionDown
            optionDown = down
            // 先记账再打印：print + fflush 要一毫秒上下，圈进计时区间就成了假的回调成本。
            record(began)
            if edge { note(down ? "⌥ 按下" : "⌥ 松开 —— 切换在这一刻确认") }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == tabKey, event.flags.contains(.maskAlternate) else {
                if stalls, code == Int64(kVK_Escape) {
                    note("Esc：故意把回调卡住 3 秒，等系统停用 tap⋯⋯")
                    Thread.sleep(forTimeInterval: 3)
                    // 这一条不记账：三秒是我们自己塞进去的，混进直通成本里会把统计变成废数。
                    return Unmanaged.passUnretained(event)
                }
                record(began)
                return Unmanaged.passUnretained(event)
            }
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            swallowingTab = true
            swallowedDown += 1
            if repeated { repeats += 1 }
            note("吞掉 ⌥Tab 按下\(repeated ? "（自动重复 —— 连按能推进选择）" : "")")
            return nil

        case .keyUp:
            // 抬起必须按状态吞，不能再按「flags 里有没有 ⌥」判：
            // 快切的常见次序是 ⌥Tab 按下 → 松开 ⌥ 确认 → 几毫秒后才松开 Tab。
            // 那条 Tab 抬起身上已经没有 ⌥ 了，照 flags 判就会漏出去，
            // 前台 App 收到一条没有配对按下的 Tab 抬起。
            guard event.getIntegerValueField(.keyboardEventKeycode) == tabKey, swallowingTab else {
                record(began)
                return Unmanaged.passUnretained(event)
            }
            swallowingTab = false
            swallowedUp += 1
            note("吞掉 ⌥Tab 抬起（与按下配对）")
            return nil

        default:
            record(began)
            return Unmanaged.passUnretained(event)
        }
    }

    private func record(_ began: UInt64) {
        costs.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1000)
    }

    /// 队尾看到的东西。只对本该被吞掉的那一种出声。
    private func inspectDownstream(type: CGEventType, event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == tabKey,
              event.flags.contains(.maskAlternate)
        else { return }
        leaks += 1
        note("⚠️ 漏到下游：⌥Tab \(type == .keyDown ? "按下" : "抬起") 走到了送进 App 之前的最后一站")
    }

    // MARK: 报告

    private func report(seconds: Double) {
        print("拦截式 event tap 探针（计划书 §6 M6 / §8「event tap 仅供观察」的推翻项）\n")
        print("  主 tap    .cgSessionEventTap / headInsert / .defaultTap  ← 可以吞")
        print("  探测 tap  .cgAnnotatedSessionEventTap / tailAppend / .listenOnly")
        print("            它在事件送进 App 之前的最后一站，看见 ⌥Tab 即为漏。")
        if stalls { print("  --stall   按 Esc 会把回调卡死 3 秒，期间整个会话的键盘输入都停。") }
        print("""

        请依次做这几件事，每件之间隔两三秒：
          1. 切到 TextEdit（能看见字符的 App 都行），按住 ⌥ 连按几次 Tab
             —— 屏幕上不该出现制表符，这里应当每次都记一行「吞掉」
          2. 松开 ⌥，单独按一次 Tab —— 这一次应当照常插入制表符
          3. 正常打一句话 —— 不该丢字、不该发卡
        """)
        print("\n\(Int(seconds)) 秒后自动退出并给出统计。\n")
        atexit_b { KeyTapProbe.shared?.summarize() }
        KeyTapProbe.shared = self
        fflush(stdout)
    }

    /// atexit 的块捕获不了实例，经全局取。探针一个进程只有一支。
    static var shared: KeyTapProbe?

    fileprivate func summarize() {
        print("\n—— 统计 ——")
        print("吞掉 ⌥Tab：按下 \(swallowedDown) 次（其中自动重复 \(repeats) 次）、抬起 \(swallowedUp) 次")
        // 一次都没按就报「没漏」是假的通过。没有正面样本时说清楚这一条没测到。
        if swallowedDown == 0 {
            print("漏到下游：没按过 ⌥Tab，问题 ② 这一轮没测到")
        } else {
            print("漏到下游：\(leaks) 次" + (leaks == 0 ? "  ← 问题 ② 通过" : "  ← 问题 ② 不通过"))
        }
        // 配平要把自动重复扣掉：一次长按会刷出一串按下，抬起始终只有一条。
        // 不扣的话长按一次就报「没配上」，是个响得很大声的假警报。
        let pressed = swallowedDown - repeats
        if pressed != swallowedUp {
            print("⚠️ 按下与抬起没配上（去掉自动重复后 \(pressed) / \(swallowedUp)）——"
                  + "有 Tab 抬起漏给了前台 App，问题 ② 不通过")
        }
        print("被系统停用：\(disables) 次")
        guard !costs.isEmpty else {
            print("直通事件：0 条，回调成本没测到（问题 ⑤ 未答）")
            return
        }
        let sorted = costs.sorted()
        print(String(format: "直通事件回调耗时：%d 条  中位 %.1fµs  P95 %.1fµs  最大 %.1fµs",
                     sorted.count, sorted[sorted.count / 2],
                     sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                     sorted[sorted.count - 1]))
    }
}

func commandKeyTap(seconds: Double, stalls: Bool) {
    KeyTapProbe(stalls: stalls).start(seconds: seconds)
}
