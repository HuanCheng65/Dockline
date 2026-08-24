import AppKit
import Carbon.HIToolbox
import DocklineCore

/// 全屏转场防闪（计划书 §3）。
///
/// `activeSpaceDidChangeNotification` 晚于转场动画，bar 会被拍进系统的转场快照、
/// 闪烁一次。这里用一个只读的 event tap 预判全屏动作，在快照之前先隐藏。
///
/// 只观察不拦截：事件原样通过，判错的代价只是 bar 白隐藏一下，1 秒后自己回来。
/// 覆盖不到的情况有两处，均属已知：绿灯的悬停菜单（其中的分屏项不是一次点击），
/// 以及 Secure Input 期间——那时系统不向 event tap 下发事件。
final class FullscreenWatch {
    /// 预判后等 Space 切换的时限。等不到就说明判错了，例如点的是缩放而不是全屏。
    private static let timeout: TimeInterval = 1.0

    /// 预判到全屏动作
    var onPredict: (() -> Void)?
    /// 预判落空，撤销预先的隐藏
    var onTimeout: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: DispatchWorkItem?

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<FullscreenWatch>.fromOpaque(refcon).takeUnretainedValue()
                        .handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Timeline.log("⚠️ 全屏转场防闪不可用：event tap 创建失败")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Space 真的切换了，撤销超时。
    func confirm() {
        pending?.cancel()
        pending = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统会因回调超时或用户输入停用 tap。不重新启用，这个功能就静默失效了。
            guard let tap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            Timeline.log("event tap 被系统停用，已重新启用")
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // ⌃⌘F 是全屏；本体自己的铺满快捷键 ⌃⌥⌘F 只多一个 Option，
            // 不排掉的话每次铺满都会先把 bar 白隐藏一秒。
            guard code == Int64(kVK_ANSI_F),
                  event.flags.contains(.maskControl), event.flags.contains(.maskCommand),
                  !event.flags.contains(.maskAlternate)
            else { return }
            predict()
        case .leftMouseDown:
            // AX 命中测试是跨进程调用，不能在事件回调里做——回调一慢，系统会停用整个 tap。
            let location = event.location
            DispatchQueue.main.async { [weak self] in self?.checkGreenButton(at: location) }
        default:
            return
        }
    }

    private func checkGreenButton(at location: CGPoint) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y),
                                               &element) == .success,
              let element,
              axCopy(element, kAXSubroleAttribute) as? String == "AXFullScreenButton"
        else { return }
        predict()
    }

    private func predict() {
        onPredict?()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onTimeout?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)
    }
}
