import AppKit
import ApplicationServices

/// 把一扇窗口迁到另一个 Space（计划书 §5 第 1.5 层）。
///
/// 这是本项目**唯一**的 Spaces 写操作，边界由 §2 的例外条款划死：不进常驻路径、
/// 不承担任何核心语义、只由用户的一次显式手势触发、能力缺席就整条不可用。
/// 因此它不并进 `SkyLight`——那个封装的语义是「App 运行路径要用的只读族」，
/// 混进一个写操作会让两者的风险等级看起来一样。
///
/// **能走通的只有这一条**（`docklinespike bridge` 实测，26.5.2 / SIP 开启 / 13–19ms，
/// 微信、Arc、Bitwarden 三个 App 复现）：
///
///     [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc]
///         initWithWindows:@[@(wid)] spaceID:space] performWithWMBridgeDelegate]
///
/// 试过并且**对别人家的窗口一律无效**的有四条：`SLSMoveWindowsToManagedSpace` 直连、
/// 用窗口所有者的连接号调同一个函数、`SLSAddWindowsToSpaces` + `SLSRemoveWindowsFromSpaces`
/// 那一对、以及同一个对象上的 `invokeFallback`。其中直连那条对**本进程自己的**窗口是
/// 好用的，所以调用形状、数组里数字的类型、目标 Space 的取值都对——差别只在窗口归谁。
///
/// **为什么这条可以而直连不行，没有查清。** 不知道原因就估不准它有多容易随点版本更新
/// 断掉，所以能力判定按类与选择子探（不按系统版本号），缺了就让调用点整条降级。
public enum SpaceMove {
    private static let className = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    private static let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
    private static let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")

    /// Swift 不暴露 `objc_msgSend`，从本进程符号表里取。参数全是寄存器可传的
    /// （id / SEL / id / uint64），按具体原型 bitcast 是安全的。
    private static let msgSend: UnsafeMutableRawPointer? =
        dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend")

    private static let operationClass: AnyClass? = objc_getClass(className) as? AnyClass

    /// 缺什么。空 = 这条能力可用。调用点据此在启动自检里报一行，不静默降级。
    public static var missing: [String] {
        var missing: [String] = []
        if msgSend == nil { missing.append("objc_msgSend") }
        guard let operationClass else { return missing + [className] }
        if !operationClass.instancesRespond(to: initSelector) {
            missing.append("\(className) -initWithWindows:spaceID:")
        }
        if !operationClass.instancesRespond(to: performSelector) {
            missing.append("\(className) -performWithWMBridgeDelegate")
        }
        return missing
    }

    public static var available: Bool { missing.isEmpty }

    /// 某块屏此刻停在哪个 Space 上。多显示器各自有 Current Space。
    public static func currentSpace(on display: CGDirectDisplayID) -> UInt64? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, uuid) as String?,
              let managed = SkyLight.managedDisplaySpaces()?.first(where: {
                  $0["Display Identifier"] as? String == identifier
              }),
              let current = managed["Current Space"] as? [String: Any] else { return nil }
        return (current["id64"] as? NSNumber)?.uint64Value
    }

    /// 目标必须是普通桌面 Space。原生全屏与拼贴那类是特殊 managed space，
    /// 按普通 Space 处理会出什么没有实测过，所以一律不认（计划书 §9）。
    public static func isDesktop(_ space: UInt64) -> Bool {
        SkyLight.spaceType(of: space) == SkyLight.desktopSpaceType
    }

    /// 迁。返回 false = 能力不可用或目标不是桌面 Space，**一个字都没写下去**。
    ///
    /// 返回 true 只表示调用发出去了。这个操作是异步的、不给错误码，成没成只能看
    /// `SkyLight.spaces(for:)`——所以调用点必须等归属确认，不能当它同步。
    @discardableResult
    public static func move(_ wid: CGWindowID, to space: UInt64) -> Bool {
        guard available, let cls = operationClass, let msgSend, isDesktop(space) else {
            return false
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
        guard let raw = unsafeBitCast(msgSend, to: AllocFn.self)(cls, NSSelectorFromString("alloc")),
              let operation = unsafeBitCast(msgSend, to: InitFn.self)(
                raw, initSelector, [NSNumber(value: wid)] as NSArray, space)
        else { return false }
        unsafeBitCast(msgSend, to: VoidFn.self)(operation, performSelector)
        return true
    }
}
