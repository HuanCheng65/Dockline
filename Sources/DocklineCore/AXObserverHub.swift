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

    /// 某个进程不应答辅助功能，已经交给通道三。带上它耗掉的时长，因为「不应答」
    /// 与「还没就绪」在返回码上分不开，是靠耗时认出来的。
    public var onUnresponsive: ((pid_t, TimeInterval) -> Void)?

    /// 注册通知是**同步 IPC**：对面不应答就一路等到超时。默认超时是 3 秒，
    /// 而本仓库其余九处 AX 调用都设了 0.2~1.0 秒——这里先前是唯一一处没设的。
    private static let timeout: TimeInterval = 0.5

    /// 跑 AX 注册的那条串行队列。**注册必须离开主线程**：实测一个不应答的
    /// 网页内容子进程每次订阅卡满 3 秒，而重试阶梯会再试七次——启动头十秒的
    /// 主线程有三分之二耗在这一件事上，条画出来了却一直是空的。
    ///
    /// 队列里只跑 IPC。观察者的 runloop source 要挂在主 runloop 上，
    /// 而这个类的几个字典没有任何保护——两样都留在主线程。
    private let wire = DispatchQueue(label: "dev.starrydream.Dockline.ax-subscribe")
    /// 已经派出去、还没回来的。不挡的话同一个进程会被排队好几遍。
    private var subscribing = Set<pid_t>()

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

    /// 一次注册尝试的结果。
    ///
    /// 「还没就绪」与「不应答」在返回码上是同一个 `cannotComplete`，**分开靠的是耗时**：
    /// AX 树没建好会立刻回错，进程不应答则要耗满超时。这个区分是必须的——重试阶梯
    /// 是按前者设计的（失败免费，所以敢 80 毫秒就再试一次），拿它去重试后者，
    /// 那串延迟会被超时整个淹没，八次尝试变成八个超时。
    private enum Attempt {
        case ready(AXObserver)
        case notReadyYet
        case unresponsive(TimeInterval)
    }

    /// 订阅一个 App。注册本身在后台队列上跑，回到主线程才动这个类的状态。
    ///
    /// 刚启动的 App 其 AX 树尚未就绪，注册会返回 cannotComplete，此时按上表重试；
    /// 重试用尽、或者对面压根不应答，都记入 failedProcesses 交由通道三兜底
    /// （不静默假装成功）。不应答的那些不再走阶梯：等它八遍没有意义，而用户激活它
    /// 的时候本来就会重试一次（见 `World.start` 里的 didActivateApplication）。
    public func observe(pid: pid_t, attempt: Int = 0) {
        guard observers[pid] == nil, !subscribing.contains(pid) else { return }
        subscribing.insert(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        wire.async { [weak self] in
            let outcome = Self.register(pid: pid, context: context)
            DispatchQueue.main.async {
                guard let self else { return }
                self.subscribing.remove(pid)
                switch outcome {
                case .ready(let observer):
                    CFRunLoopAddSource(CFRunLoopGetMain(),
                                       AXObserverGetRunLoopSource(observer), .defaultMode)
                    self.observers[pid] = observer
                    self.failedProcesses.remove(pid)
                    self.onReady?(pid)
                case .notReadyYet:
                    self.retry(pid: pid, attempt: attempt)
                case .unresponsive(let cost):
                    self.failedProcesses.insert(pid)
                    self.onUnresponsive?(pid, cost)
                }
            }
        }
    }

    /// 纯 IPC，不碰这个类的任何状态——它跑在 `wire` 上。
    private static func register(pid: pid_t, context: UnsafeMutableRawPointer) -> Attempt {
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success,
              let observer else { return .notReadyYet }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Float(timeout))
        let began = Date()
        var anyRegistered = false
        for name in appNotifications {
            if AXObserverAddNotification(observer, appElement, name as CFString, context) == .success {
                anyRegistered = true
            }
        }
        if anyRegistered { return .ready(observer) }
        let cost = Date().timeIntervalSince(began)
        // 耗满了超时就是对面不应答；立刻回错则是 AX 树还没建好，值得再等一下
        return cost >= timeout ? .unresponsive(cost) : .notReadyYet
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
    ///
    /// 这一路仍在主线程上：能走到这里的窗口，其 App 已经答过 AX 了——没拿到 AX 引用
    /// 的窗口在上游就被跳过（见 `World.subscribeToKnownWindows`）。所以这里遇不上
    /// `observe` 那种彻底不应答的进程，补一道超时封住上限即可。
    public func watch(window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let wrapper = AXUIElementWrapper(window)
        guard watchedWindows[pid]?.contains(wrapper) != true else { return }
        AXUIElementSetMessagingTimeout(window, Float(Self.timeout))
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
