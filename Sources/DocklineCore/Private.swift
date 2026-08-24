import Foundation
import ApplicationServices

// MARK: - 第 0 层私有符号：AX 元素 -> CGWindowID
// 存在于 HIServices（ApplicationServices 的一部分），直接静态链接。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 成功返回 (id, .success)；失败返回 (nil, 具体 AXError)，调用点负责报告。
public func windowID(of element: AXUIElement) -> (id: CGWindowID?, error: AXError) {
    var wid: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &wid)
    return err == .success ? (wid, .success) : (nil, err)
}

// MARK: - 第 1 层私有符号：SkyLight 只读族
// 用 dlsym 动态解析，缺失时 available == false，调用点显式降级并打印原因。
public enum SkyLight {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private typealias WindowIsOrderedInFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias SpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias CopyManagedDisplaySpacesFn =
        @convention(c) (Int32) -> Unmanaged<CFArray>?
    /// 窗口服务器事件的回调：(事件号, 数据, 长度, 注册时给的上下文)
    public typealias NotifyProc =
        @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterNotifyProcFn =
        @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let mainConnectionID = sym("SLSMainConnectionID", as: MainConnectionIDFn.self)
    private static let copySpacesForWindows = sym("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let getActiveSpace = sym("SLSGetActiveSpace", as: GetActiveSpaceFn.self)
    private static let windowIsOrderedIn = sym("SLSWindowIsOrderedIn", as: WindowIsOrderedInFn.self)
    private static let spaceGetType = sym("SLSSpaceGetType", as: SpaceGetTypeFn.self)
    private static let copyManagedDisplaySpaces =
        sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    private static let registerNotifyProc = sym("SLSRegisterNotifyProc", as: RegisterNotifyProcFn.self)

    /// 启动自检：任一符号缺失即视为整族不可用。
    public static var missingSymbols: [String] {
        var missing: [String] = []
        if handle == nil { return ["SkyLight.framework (dlopen 失败)"] }
        if mainConnectionID == nil { missing.append("SLSMainConnectionID") }
        if copySpacesForWindows == nil { missing.append("SLSCopySpacesForWindows") }
        if getActiveSpace == nil { missing.append("SLSGetActiveSpace") }
        if windowIsOrderedIn == nil { missing.append("SLSWindowIsOrderedIn") }
        if spaceGetType == nil { missing.append("SLSSpaceGetType") }
        if copyManagedDisplaySpaces == nil { missing.append("CGSCopyManagedDisplaySpaces") }
        if registerNotifyProc == nil { missing.append("SLSRegisterNotifyProc") }
        return missing
    }

    public static var available: Bool { missingSymbols.isEmpty }

    private static var connection: Int32? { mainConnectionID?() }

    public static var activeSpace: UInt64? {
        guard let cid = connection, let fn = getActiveSpace else { return nil }
        return fn(cid)
    }

    /// 窗口是否在窗口服务器的显示列表里。被 orderOut: 关掉的窗口对象仍然存在、
    /// 仍然挂在原 Space 上，但 ordered-in 为 false——这是「真窗口」与「僵尸 surface」的判别式。
    /// 返回 nil = 符号不可用或调用出错（调用点负责显式报告，不静默当成 false）。
    public static func isOrderedIn(_ wid: CGWindowID) -> Bool? {
        guard let cid = connection, let fn = windowIsOrderedIn else { return nil }
        var value = false
        return fn(cid, wid, &value) == 0 ? value : nil
    }

    /// 原生全屏会把窗口放进一个专属 Space，其 type 为 4（普通桌面 Space 为 0）。
    /// 本机实测确认，取值不是照抄社区常量。
    ///
    /// 不用「visibleFrame == frame」这个公开 API 土办法判全屏：用户若开了
    /// 「自动隐藏与显示菜单栏」，普通桌面下两者也相等，会让 bar 永久隐藏。
    /// 那是个静默失效，宁可多用一个只读符号。
    private static let fullscreenSpaceType: Int32 = 4

    /// nil = 符号不可用。调用点必须显式处理，不得静默当作「不是全屏」。
    public static var activeSpaceIsFullscreen: Bool? {
        guard let cid = connection, let active = activeSpace, let fn = spaceGetType else { return nil }
        return fn(cid, active) == fullscreenSpaceType
    }

    /// 指定显示器当前 Space 是否为原生全屏。多显示器各自有 Current Space，不能使用
    /// `SLSGetActiveSpace`：后者返回全局最近激活的 Space，会把另一块屏上的 Dockline 也收掉。
    public static func activeSpaceIsFullscreen(on display: CGDirectDisplayID) -> Bool? {
        guard let cid = connection, let fn = copyManagedDisplaySpaces else { return nil }
        let uuid = CGDisplayCreateUUIDFromDisplayID(display).takeRetainedValue()
        let identifier = CFUUIDCreateString(nil, uuid) as String
        guard let raw = fn(cid)?.takeRetainedValue() as? [[String: Any]],
              let managed = raw.first(where: {
                  $0["Display Identifier"] as? String == identifier
              }),
              let current = managed["Current Space"] as? [String: Any],
              let type = current["type"] as? NSNumber else { return nil }
        return type.int32Value == fullscreenSpaceType
    }

    /// 订阅窗口服务器的一类事件。事件号没有公开清单，取值由实测确定，见调用点。
    /// 返回 false = 符号不可用，调用点负责报告并关掉对应功能。
    public static func onEvent(_ type: UInt32, context: UnsafeMutableRawPointer?,
                               _ proc: NotifyProc) -> Bool {
        guard let fn = registerNotifyProc else { return false }
        fn(proc, type, context)
        return true
    }

    /// kCGSAllSpacesMask == 0x7：返回该窗口所属的全部 space id。
    public static func spaces(for wid: CGWindowID) -> [UInt64]? {
        guard let cid = connection, let fn = copySpacesForWindows else { return nil }
        guard let result = fn(cid, 0x7, [wid] as CFArray) else { return nil }
        return (result.takeRetainedValue() as? [NSNumber])?.map { $0.uint64Value }
    }
}
