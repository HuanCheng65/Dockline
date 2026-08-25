import AppKit
import ApplicationServices

// MARK: - 坐标系换算
// AX 用全局左上原点、y 向下；AppKit 用主屏左下原点、y 向上。互换是同一个公式。

public func primaryTop() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

public func flipY(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.origin.x, y: primaryTop() - rect.maxY, width: rect.width, height: rect.height)
}

/// NSScreen 对象在屏幕参数变化时会被重建，比对身份要用显示器编号。
public func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

/// 显示器的持久身份。`CGDirectDisplayID` 在拔插之后会被重新分配，凡是要跨拔插存活的
/// 记录都必须用 UUID 做键——用编号做键会让「同一块屏又回来了」这个判断静默失效。
public func displayUUID(_ display: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
        return nil
    }
    return CFUUIDCreateString(nil, uuid) as String?
}

// MARK: - 召回
// M0 验收：常规路径（AXRaise + activate）在跨 Space、原生全屏、非宿主 App 下均成立，
// 且能带动 Space 自动切换。最小化者先写 AXMinimized=false。

public struct RaiseOutcome {
    public let unminimize: AXError?   // nil = 本来就没最小化
    public let raise: AXError
    public let activated: Bool
}

@discardableResult
public func raiseWindow(_ window: WindowRecord) -> RaiseOutcome {
    raiseWindow(element: window.element, pid: window.pid, minimized: window.minimized == true)
}

@discardableResult
public func raiseWindow(element: AXUIElement, pid: pid_t, minimized: Bool) -> RaiseOutcome {
    var unminimize: AXError?
    if minimized {
        unminimize = AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
    }
    let raise = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    let activated = NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    return RaiseOutcome(unminimize: unminimize, raise: raise, activated: activated)
}

/// bar 点击格子的统一入口。
/// 有 AX 引用走常规路径；其他 Space 的存量窗口无引用，退回 §4 的「激活 App」粗路，
/// 切换后下一次对账会补抓到引用自动转正。
///
/// 已知缺口（计划书 §9）：粗路指不到具体窗口。多窗口的 App 里若有一个在原生全屏，
/// 站在别的 Space 上点它，系统会把 App 带到前台、但落在它自己挑的那个窗口上。
/// 实测这类窗口在非当前 Space 时**根本不出现在该进程的 AXWindows 里**（Code：
/// 当前 Space 938 时 AXWindows 只有 1 个），所以重取一次也拿不到，只能换机制。
@discardableResult
public func recall(_ window: IndexedWindow) -> RaiseOutcome? {
    guard let element = window.element else {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        return nil
    }
    return raiseWindow(element: element, pid: window.pid, minimized: window.minimized)
}

// MARK: - 接管最大化
//
// 目标矩形由调用点给出：只有 bar 所在的那块屏要扣掉 bar 占的一条，
// 而 bar 的几何不属于这一层。

public struct FillPass {
    public let position: AXError
    public let size: AXError
}

public struct FillOutcome {
    public let target: CGRect        // AX 坐标系
    public let before: CGRect
    public let passes: [FillPass]
    public let after: CGRect?
    /// M0 实测：部分 App 因自身尺寸约束会差 1pt，判定必须带容差。
    public var fits: Bool {
        guard let after else { return false }
        return matchesFrame(after, target)
    }
}

/// 几何比对一律带 2pt 容差，理由同上。
public func matchesFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
        && abs(a.origin.x - b.origin.x) < 2 && abs(a.origin.y - b.origin.y) < 2
}

public enum FillError: Error {
    case noGeometry          // 读不到 AXPosition/AXSize
    case noScreen
}

/// 窗口所在的屏，按窗口中心判定。
public func screen(of element: AXUIElement) throws -> NSScreen {
    guard let rect = axRect(element) else { throw FillError.noGeometry }
    let center = CGPoint(x: flipY(rect).midX, y: flipY(rect).midY)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    else { throw FillError.noScreen }
    return screen
}

/// 把窗口写到目标矩形（AX 坐标系）。
/// 计划书 §3：先位置后尺寸，连写两次——首遍常被 App 的尺寸约束夹回。
public func setFrame(_ element: AXUIElement, to target: CGRect) throws -> FillOutcome {
    guard let before = axRect(element) else { throw FillError.noGeometry }
    var passes: [FillPass] = []
    for _ in 1...2 {
        var origin = target.origin
        var size = target.size
        passes.append(FillPass(
            position: AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString,
                                                   AXValueCreate(.cgPoint, &origin)!),
            size: AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString,
                                               AXValueCreate(.cgSize, &size)!)))
    }
    return FillOutcome(target: target, before: before, passes: passes, after: axRect(element))
}

// MARK: - 最小化

/// 点击当前前台窗口的格子时把它收起。
/// 返回 nil 表示没有 AX 引用——跨 Space 的存量窗口不可能是前台窗口，调用点应走召回。
///
/// 收起之后要把焦点交还给**原本压在它下面**的那个窗口。
/// macOS 的激活是 App 级的：最小化前台窗口后，同 App 的另一个窗口会被顶到最前，
/// 哪怕它原本压在别人下面。用户的意图是「把这个窗口收走」，不是「把这个 App 的
/// 下一个窗口叫上来」——后者比 Windows 任务栏更扰人，那里的 z 序是全局按窗口的。
///
/// 只有当下面压着的是**别的 App** 的窗口时才纠正；下面本来就是同 App 的兄弟窗口，
/// 系统的行为就是对的，不必插手。
@discardableResult
public func minimizeWindow(_ window: IndexedWindow) -> AXError? {
    guard let element = window.element else { return nil }
    let successor = windowBelow(window.id)
    let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                             true as CFTypeRef)
    guard result == .success, let successor, successor.pid != window.pid else { return result }
    if let element = axWindow(pid: successor.pid, wid: successor.windowID) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
    NSRunningApplication(processIdentifier: successor.pid)?.activate()
    return result
}

/// 屏幕上紧压在某个窗口下面的那一个。
func windowBelow(_ id: CGWindowID) -> CGWindowRecord? {
    let stack = enumerateOnScreenWindowsFrontToBack().filter(isCandidate)
    guard let index = stack.firstIndex(where: { $0.windowID == id }) else { return nil }
    return stack.dropFirst(index + 1).first
}

// MARK: - 原生标签页的召回
//
// 后台标签没有 AX 元素，走不了 AXRaise。可行的路径是按标签栏上的那一项：
// 窗口子树里有一个 AXTabGroup，每个标签是一个 AXRadioButton，AXValue 标出当前选中者，
// 支持 AXPress（本机实测，访达）。

public enum TabRecallError: Error {
    case hostNotFound                  // 宿主窗口的 AX 元素找不到
    case noTabBar                      // 宿主窗口里没有标签栏
    case tabNotFound(String)
    case pressFailed(AXError)
}

public func recallTab(_ window: IndexedWindow, host: CGWindowID) throws {
    guard let hostElement = axWindow(pid: window.pid, wid: host) else {
        throw TabRecallError.hostNotFound
    }
    guard let group = tabGroup(in: hostElement) else { throw TabRecallError.noTabBar }
    let tabs = (axCopy(group, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    // 同名标签页在 AX 层没有别的可区分之处，只能按住第一个未选中的同名项。
    guard let target = tabs.first(where: {
        axCopy($0, kAXTitleAttribute) as? String == window.title
            && (axCopy($0, kAXValueAttribute) as? NSNumber)?.intValue != 1
    }) else { throw TabRecallError.tabNotFound(window.title) }

    let pressed = AXUIElementPerformAction(target, kAXPressAction as CFString)
    guard pressed == .success else { throw TabRecallError.pressFailed(pressed) }
    NSRunningApplication(processIdentifier: window.pid)?.activate()
}

func axWindow(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    guard let windows = axCopy(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    return windows.first { windowID(of: $0).id == wid }
}

/// 标签栏在窗口子树里的深度不固定，逐层找到 AXTabGroup 为止。
func tabGroup(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 3 else { return nil }
    for child in (axCopy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if axCopy(child, kAXRoleAttribute) as? String == "AXTabGroup" { return child }
        if let found = tabGroup(in: child, depth: depth + 1) { return found }
    }
    return nil
}
