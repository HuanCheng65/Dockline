import AppKit
import ApplicationServices

/// 计划书 §4 通道二：对每个运行中 App 订阅 AX 通知，这是低延迟主通道。
///
/// 注册分两层——这个拆分是必须的：
///  · App 元素上注册「窗口创建 / 焦点窗口变更」
///  · 每个窗口元素上单独注册「销毁 / 标题变更 / 最小化 / 取消最小化」
/// 在 App 元素上注册窗口级通知并不可靠，必须逐窗口注册。
public final class AXObserverHub {
    /// (pid, 通知名, 事件源元素) —— 元素用于识别被销毁的具体窗口
    public var onEvent: ((pid_t, String, AXUIElement) -> Void)?

    /// 订阅刚刚建立时回调。此前发生的事件必然已经错过（App 启动时 AX 树未就绪，
    /// 注册会失败重试，窗口往往就在这段空窗期里创建），所以必须在这一刻主动同步一次。
    public var onReady: ((pid_t) -> Void)?

    /// 窗口移动 / 尺寸变化。单独一条回调，不并进 onEvent——
    /// 拖拽窗口时它每一帧都触发，走主通道等于把每一像素的拖动都变成一次 AX 全量刷新。
    public var onGeometryChanged: ((AXUIElement) -> Void)?


    /// 重试用尽仍未订阅成功的进程。这些 App 的窗口变化只能靠通道三兜底。
    public private(set) var failedProcesses = Set<pid_t>()

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]
    /// 窗口级通知。**移动与缩放一律订阅**，不看「结果纠正」开不开。
    ///
    /// 它们原先只为纠正而订阅，于是关掉纠正时，窗口被拖到另一块屏这件事**一条事件都没有**
    /// ——那一格该挪到哪条 bar 上，只能靠定时对账看出来，而那一遍是这个进程闲着时的
    /// 主要开销。要不要纠正是处理端的事（见 `Maximize.handle` 里的 `enabled`），
    /// 与「边界变了要不要知道」不是同一个问题。
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: [pid_t: Set<AXUIElementWrapper>] = [:]

    public init() {}

    public var watchedProcessCount: Int { observers.count }

    /// 重试节奏：前几次要密，App 启动到 AX 就绪通常在数百毫秒内。
    private static let retryDelays: [TimeInterval] = [0.08, 0.15, 0.25, 0.4, 0.6, 0.9, 1.4]

    /// 订阅一个 App。刚启动的 App 其 AX 树尚未就绪，注册会返回 cannotComplete，
    /// 此时按上表重试；重试用尽则记入 failedProcesses 并交由通道三兜底（不静默假装成功）。
    public func observe(pid: pid_t, attempt: Int = 0) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let created = AXObserverCreate(pid, axObserverCallback, &observer)
        guard created == .success, let observer else {
            retry(pid: pid, attempt: attempt)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var anyRegistered = false
        for name in Self.appNotifications {
            if AXObserverAddNotification(observer, appElement, name as CFString, context) == .success {
                anyRegistered = true
            }
        }
        guard anyRegistered else {
            retry(pid: pid, attempt: attempt)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        failedProcesses.remove(pid)
        onReady?(pid)
    }

    private func retry(pid: pid_t, attempt: Int) {
        guard attempt < Self.retryDelays.count else {
            failedProcesses.insert(pid)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
            self?.observe(pid: pid, attempt: attempt + 1)
        }
    }

    /// 为已知窗口注册窗口级通知。重复调用安全。
    public func watch(window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let wrapper = AXUIElementWrapper(window)
        guard watchedWindows[pid]?.contains(wrapper) != true else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, context)
        }
        watchedWindows[pid, default: []].insert(wrapper)
    }

    public func stop(pid: pid_t) {
        failedProcesses.remove(pid)
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        watchedWindows[pid] = nil
        failedProcesses.remove(pid)
    }

    fileprivate func dispatch(element: AXUIElement, notification: String) {
        // 移动与缩放**两条路都要走**：纠正那一路要元素本身，索引那一路要知道边界变了
        // ——一格该落在哪块屏上是按边界算的。原先它只走纠正那一路就返回了，于是即便
        // 订阅着，索引也收不到窗口换屏这件事，只能等定时对账看出来。
        if notification == kAXWindowMovedNotification
            || notification == kAXWindowResizedNotification {
            onGeometryChanged?(element)
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        onEvent?(pid, notification, element)
    }
}

/// AXUIElement 不是 Hashable，用 CFHash / CFEqual 包一层以便去重。
private struct AXUIElementWrapper: Hashable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (a: AXUIElementWrapper, b: AXUIElementWrapper) -> Bool {
        CFEqual(a.element, b.element)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AXObserverHub>.fromOpaque(refcon).takeUnretainedValue()
        .dispatch(element: element, notification: notification as String)
}
