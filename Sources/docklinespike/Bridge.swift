import AppKit
import DocklineCore

// MARK: - bridge —— 跨 Space 迁移一个窗口（计划书 §2 的写操作例外 / §6 M6 spike）
//
// 要回答的问题：**SIP 开着的时候，能不能把别的 Space 上的一个普通窗口迁到当前 Space。**
// 拖格子分屏对跨 Space 的窗口成不成立，全看这一条；不成立就只能维持「不上膛」的降级。
//
// 结论（26.5.2 / SIP 开启）：**能**，走这一条，13–19ms：
//
//   [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc]
//       initWithWindows:@[@(wid)] spaceID:space] performWithWMBridgeDelegate]
//
// 社区流传的配方把它交给 `SLSPerformAsynchronousBridgedWindowManagementOperation`，
// 那个 C 函数在本机的导出表里没有——但那不构成障碍，直接给操作对象发
// `performWithWMBridgeDelegate` 就成。（这条一度被推理否掉过：`…BridgeSetDelegate`
// 是设置方，于是想当然地认为普通进程里没有 delegate、这条走不通，**根本没试**。
// 一试就通。能直接调的东西不要用推理替代。）
//
// 另外四条对**别人家的**窗口一律无效，且都不给错误码：`SLSMoveWindowsToManagedSpace`
// 直连、拿窗口所有者的连接号调同一个函数、`SLSAddWindowsToSpaces` +
// `SLSRemoveWindowsFromSpaces` 那一对、以及同一个对象上的 `invokeFallback`。
// 其中直连那条**对本进程自己的窗口是好用的**（`--self` 那个对照），所以调用形状、
// 数组里数字的类型、目标 Space 的取值都对——差别只在窗口归谁。**这个对照是整套结论的
// 地基**：没有它，「别人家的迁不动」分不出是权限还是写法。
//
// 全部路线都是 void，**判定只能看效果**：迁移前后各读一次 `SLSCopySpacesForWindows`，
// 轮询到它真的变了为止——顺带量出这件事有多异步，那是「迁完多久才能安全地召回并摆位」
// 的依据。迁完还要等 AX 引用出现（实测 36–60ms），否则几何写不下去。
//
//   docklinespike bridge                       只读：Space 拓扑、桥接面、可试的窗口
//   docklinespike bridge --wid n [--space s] [--via 路线] [--activate]
//   docklinespike bridge --self                拿本进程自己的窗口做对照
//
// 不带 `--wid` / `--self` 时**一个字都不写**。

// MARK: - 符号

/// 写操作刻意不进 `DocklineCore.SkyLight`。那个封装的语义是「App 运行路径要用的只读族」，
/// 而要不要引入这个写操作，正是这次 spike 要回答的问题——答案出来之前不给出这个口子。
private enum Bridge {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let mainConnectionID = sym("SLSMainConnectionID", as: MainConnectionIDFn.self)
    private static let moveWindows = sym("SLSMoveWindowsToManagedSpace", as: MoveWindowsFn.self)
    /// 另一对经典写法：加进目标 Space、再从原来那些里移出。yabai 历史上两套都用过，
    /// 权限判定未必一样，所以并排试。
    private typealias SpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private static let addToSpaces = sym("SLSAddWindowsToSpaces", as: SpacesFn.self)
    private static let removeFromSpaces = sym("SLSRemoveWindowsFromSpaces", as: SpacesFn.self)

    /// Swift 不暴露 `objc_msgSend`，从本进程符号表里取。全部参数都能进寄存器
    /// （id / SEL / id / uint64），按具体原型 bitcast 是安全的；可变参数那套不涉及。
    private static let msgSend: UnsafeMutableRawPointer? = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend")

    static var connection: Int32? { mainConnectionID?() }

    static var directAvailable: Bool { moveWindows != nil }
    static var operationClass: AnyClass? {
        objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation") as? AnyClass
    }
    static var bridgeAvailable: Bool { operationClass != nil && msgSend != nil }
    static var delegateSetterAvailable: Bool {
        handle.flatMap { dlsym($0, "SLSWindowManagementBridgeSetDelegate") } != nil
    }

    private typealias GetWindowOwnerFn =
        @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    private static let getWindowOwner = sym("SLSGetWindowOwner", as: GetWindowOwnerFn.self)

    /// 窗口归哪个窗口服务器连接。写操作历来是「本连接的窗口随便动，别人的不行」，
    /// 所以拿所有者的连接号再调一次是必须排掉的一种可能。
    static func owner(of wid: CGWindowID) -> Int32? {
        guard let cid = connection, let getWindowOwner else { return nil }
        var owner: Int32 = 0
        return getWindowOwner(cid, wid, &owner) == 0 ? owner : nil
    }

    static let routes = ["direct", "as-owner", "addremove", "fallback", "delegate"]

    /// 走某一条路。返回 nil = 调下去了（成没成要看归属），非 nil = 压根没调成。
    static func perform(_ route: String, _ wid: CGWindowID, to space: UInt64) -> String? {
        switch route {
        case "direct": return moveDirect(wid, to: space)
        case "as-owner": return moveAsOwner(wid, to: space)
        case "addremove": return moveByAddRemove(wid, to: space)
        case "fallback": return moveViaFallback(wid, to: space)
        case "delegate": return moveViaDelegate(wid, to: space)
        default: return "不认识的路线 \(route)"
        }
    }

    /// 直连：经典写函数。
    static func moveDirect(_ wid: CGWindowID, to space: UInt64) -> String? {
        guard let cid = connection else { return "取不到主连接号" }
        guard let moveWindows else { return "SLSMoveWindowsToManagedSpace 不存在" }
        moveWindows(cid, [NSNumber(value: wid)] as CFArray, space)
        return nil
    }

    /// 拿窗口所有者的连接号去调。
    static func moveAsOwner(_ wid: CGWindowID, to space: UInt64) -> String? {
        guard let moveWindows else { return "SLSMoveWindowsToManagedSpace 不存在" }
        guard let owner = owner(of: wid) else { return "取不到窗口的所有者连接号" }
        moveWindows(owner, [NSNumber(value: wid)] as CFArray, space)
        return nil
    }

    /// 加进去、再从旧的移出来。
    static func moveByAddRemove(_ wid: CGWindowID, to space: UInt64) -> String? {
        guard let cid = connection else { return "取不到主连接号" }
        guard let addToSpaces, let removeFromSpaces else {
            return "SLSAddWindowsToSpaces / SLSRemoveWindowsFromSpaces 不存在"
        }
        let windows = [NSNumber(value: wid)] as CFArray
        let old = (SkyLight.spaces(for: wid) ?? []).filter { $0 != space }
        addToSpaces(cid, windows, [NSNumber(value: space)] as CFArray)
        if !old.isEmpty {
            removeFromSpaces(cid, windows, old.map { NSNumber(value: $0) } as CFArray)
        }
        return nil
    }

    /// 构造出来的操作对象自己认不认这两个入参。**这一步要单独验**：两条迁移路都是 void，
    /// 失败时分不出是「构造就没成」还是「构造成了但不许动」。
    static func describeOperation(_ wid: CGWindowID, to space: UInt64) -> String {
        guard let cls = operationClass, let msgSend else { return "类或 objc_msgSend 缺失" }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        typealias IdFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias U64Fn = @convention(c) (AnyObject, Selector) -> UInt64
        guard let raw = unsafeBitCast(msgSend, to: AllocFn.self)(cls, NSSelectorFromString("alloc")),
              let op = unsafeBitCast(msgSend, to: InitFn.self)(
                raw, NSSelectorFromString("initWithWindows:spaceID:"),
                [NSNumber(value: wid)] as NSArray, space)
        else { return "构造失败" }
        let windows = unsafeBitCast(msgSend, to: IdFn.self)(op, NSSelectorFromString("windows"))
        let readBack = unsafeBitCast(msgSend, to: U64Fn.self)(op, NSSelectorFromString("spaceID"))
        return "windows=\(windows.map(String.init(describing:)) ?? "nil") spaceID=\(readBack)"
    }

    /// 桥接：构造操作对象，走基类的 `performWithWMBridgeDelegate`。
    ///
    /// 这条不能靠推理跳过。`SLSWindowManagementBridgeSetDelegate` 是设置方这件事只说明
    /// **有人**要装 delegate，不说明本进程里一定没有——SkyLight 完全可能在连接建立时
    /// 自己装一个默认的。调下去看效果，比推断可靠。它可能因为 delegate 为空而崩，
    /// 崩本身也是一条结论，所以单独一条路线跑。
    static func moveViaDelegate(_ wid: CGWindowID, to space: UInt64) -> String? {
        guard let op = makeOperation(wid, to: space) else { return "构造失败" }
        let sel = NSSelectorFromString("performWithWMBridgeDelegate")
        guard op.responds(to: sel) else { return "对象上没有 performWithWMBridgeDelegate" }
        guard let msgSend else { return "取不到 objc_msgSend" }
        typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(msgSend, to: VoidFn.self)(op, sel)
        return nil
    }

    /// 构造一个迁移操作。三条桥接路线共用。
    private static func makeOperation(_ wid: CGWindowID, to space: UInt64) -> AnyObject? {
        guard let cls = operationClass, let msgSend else { return nil }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        guard let raw = unsafeBitCast(msgSend, to: AllocFn.self)(cls, NSSelectorFromString("alloc"))
        else { return nil }
        return unsafeBitCast(msgSend, to: InitFn.self)(
            raw, NSSelectorFromString("initWithWindows:spaceID:"),
            [NSNumber(value: wid)] as NSArray, space)
    }

    /// 桥接：构造操作对象，走 `invokeFallback`。**对别人家的窗口无效**，留着是为了
    /// 让「哪条能用」这件事在下一套系统上还能一次跑完、有对照。
    static func moveViaFallback(_ wid: CGWindowID, to space: UInt64) -> String? {
        guard let cls = operationClass else {
            return "SLSBridgedMoveWindowsToManagedSpaceOperation 不存在"
        }
        guard let msgSend else { return "取不到 objc_msgSend" }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        typealias VoidFn = @convention(c) (AnyObject, Selector) -> Void
        guard let raw = unsafeBitCast(msgSend, to: AllocFn.self)(cls, NSSelectorFromString("alloc"))
        else { return "alloc 返回空" }
        guard let op = unsafeBitCast(msgSend, to: InitFn.self)(
            raw, NSSelectorFromString("initWithWindows:spaceID:"),
            [NSNumber(value: wid)] as NSArray, space)
        else { return "initWithWindows:spaceID: 返回空" }
        guard op.responds(to: NSSelectorFromString("invokeFallback")) else {
            return "对象上没有 invokeFallback"
        }
        unsafeBitCast(msgSend, to: VoidFn.self)(op, NSSelectorFromString("invokeFallback"))
        return nil
    }
}

// MARK: - 目标 Space

/// 主显示器此刻的 Space。迁移的默认目的地就是「用户正看着的这一个」。
private func currentSpace(of display: [String: Any]) -> UInt64? {
    ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
}

private func allSpaces() -> [(display: String, current: UInt64?, spaces: [(id: UInt64, type: Int32)])] {
    (SkyLight.managedDisplaySpaces() ?? []).map { display in
        let list = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { entry -> (UInt64, Int32)? in
            guard let id = (entry["id64"] as? NSNumber)?.uint64Value else { return nil }
            return (id, SkyLight.spaceType(of: id) ?? -1)
        }
        return (display["Display Identifier"] as? String ?? "?",
                currentSpace(of: display),
                list)
    }
}

private func typeName(_ type: Int32) -> String {
    switch type {
    case SkyLight.desktopSpaceType: return "桌面"
    case SkyLight.fullscreenSpaceTypeValue: return "全屏"
    default: return "type \(type)"
    }
}

// MARK: - 只读快照

func commandBridge() {
    print("桥接面（本机 \(ProcessInfo.processInfo.operatingSystemVersionString)）")
    print("  直连 SLSMoveWindowsToManagedSpace          \(Bridge.directAvailable ? "有" : "—")")
    print("  类 SLSBridgedMoveWindowsToManagedSpace…    \(Bridge.bridgeAvailable ? "有" : "—")")
    print("  SLSWindowManagementBridgeSetDelegate      \(Bridge.delegateSetterAvailable ? "有" : "—")"
          + "  （设置方；能不能迁与它无关，看 --via delegate 的实测）")
    print("")
    let displays = allSpaces()
    for display in displays {
        print("显示器 \(display.display)")
        for space in display.spaces {
            let mark = space.id == display.current ? "→" : " "
            print("  \(mark) \(space.id)  \(typeName(space.type))")
        }
    }
    let current = Set(displays.compactMap(\.current))
    let candidates = enumerateCGWindows().filter { window in
        // 只列看得出是「一扇真窗口」的：layer 0、有正经尺寸，且一个当前 Space 都不在
        guard window.layer == 0, window.bounds.width > 200, window.bounds.height > 150,
              let spaces = SkyLight.spaces(for: window.windowID), !spaces.isEmpty else {
            return false
        }
        return spaces.allSatisfy { !current.contains($0) }
    }
    print("")
    if candidates.isEmpty {
        print("此刻没有「不在任何当前 Space 上」的窗口，切一个桌面过去再来。")
    } else {
        print("可以拿来试的窗口（都不在当前 Space 上）：")
        for window in candidates.prefix(12) {
            let spaces = (SkyLight.spaces(for: window.windowID) ?? [])
                .map(String.init).joined(separator: ",")
            print("  \(window.windowID)  在 \(spaces)  \(window.ownerName)"
                  + "  \(window.cgTitle ?? "（无标题）")")
        }
    }
    print("")
    print("迁移一个窗口：docklinespike bridge --wid <窗口号> [--space <目标>] [--via direct|fallback|both]")
    print("不带 --wid 时一个字都不写。")
}

// MARK: - 迁移

/// 迁移是异步的：判定只能看 `SLSCopySpacesForWindows` 什么时候真的变了。
/// 上限取 2 秒——比任何合理的窗口服务器往返都宽，超时就是没成。
private let settleLimit: TimeInterval = 2
private let pollStep: TimeInterval = 0.01

func commandBridgeMove(wid: CGWindowID, space requested: UInt64?, via: String,
                       activating: Bool) {
    guard let before = SkyLight.spaces(for: wid), !before.isEmpty else {
        FileHandle.standardError.write("bridge: 读不到窗口 \(wid) 的 Space 归属\n".data(using: .utf8)!)
        exit(1)
    }
    let displays = allSpaces()
    guard let target = requested ?? displays.first?.current else {
        FileHandle.standardError.write("bridge: 定不出目标 Space\n".data(using: .utf8)!)
        exit(1)
    }
    let targetType = SkyLight.spaceType(of: target) ?? -1
    // 全屏 / 拼贴那类是特殊 managed space，不能按普通 Space 处理（计划书 §6 M6）。
    guard targetType == SkyLight.desktopSpaceType else {
        FileHandle.standardError.write(
            "bridge: 目标 \(target) 是「\(typeName(targetType))」，本轮只认桌面 Space\n"
                .data(using: .utf8)!)
        exit(1)
    }
    guard !before.contains(target) else {
        print("窗口 \(wid) 已经在 \(target) 上了，没什么可迁的。顺带看一眼它的 AX 引用：")
        report(wid: wid, activating: activating)
        return
    }

    let routes = via == "both" ? Bridge.routes : [via]
    print("窗口 \(wid)：\(before.map(String.init).joined(separator: ",")) → \(target)")
    print("  操作对象：\(Bridge.describeOperation(wid, to: target))")
    for route in routes {
        let began = DispatchTime.now().uptimeNanoseconds
        let failure = Bridge.perform(route, wid, to: target)
        if let failure {
            print("  \(route)  调不动：\(failure)")
            continue
        }
        // 两条路都是 void，不给错误码，只能盯归属。
        var settled: Double?
        var seen = before
        for _ in 0..<Int(settleLimit / pollStep) {
            RunLoop.current.run(until: Date().addingTimeInterval(pollStep))
            guard let now = SkyLight.spaces(for: wid) else { continue }
            seen = now
            if now.contains(target) {
                settled = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
                break
            }
        }
        if let settled {
            print(String(format: "  %@  成了，%.0fms 后归属变为 %@",
                         route, settled, seen.map(String.init).joined(separator: ",")))
            report(wid: wid, activating: activating)
            return
        }
        print("  \(route)  \(Int(settleLimit * 1000))ms 内归属没变（仍是 "
              + "\(seen.map(String.init).joined(separator: ","))）")
    }
    print("试过的路线都没把它迁过来。若连 --via delegate 也不成，说明这条能力在这套系统上"
          + "变了——跨 Space 分屏该退回「不上膛」的降级（计划书 §2 / §6 M6）。")
}

// MARK: - 自家窗口的对照
//
// 别人家的窗口迁不动时，光看结果分不出两件事：**调用的形状不对**，还是**不许动别人家的**。
// 拿本进程自己的一扇窗口再试一次就能分开——SkyLight 的写操作历来对「本连接拥有的窗口」
// 与「别人的窗口」两套待遇，yabai 当年要往程序坞里注入 scripting addition，为的正是
// 借一个有权限的连接去下手。
//
// 自家的能迁、别人的不能 → 形状是对的，缺的是权限，那条路对我们就是死的。
// 自家的也迁不动     → 形状就不对，还有得查。

func commandBridgeSelf(space requested: UInt64?, via: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 140),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "bridge 对照窗口"
    window.orderFront(nil)

    let wid = CGWindowID(window.windowNumber)
    // 刚上屏的窗口归属会自己动一阵：等它稳住再取基线，否则把「窗口服务器本来就要挪它」
    // 记成我们的战果，就是一次假通过。
    guard let before = settledSpaces(of: wid) else {
        print("对照窗口 \(wid)：归属一直没稳下来，这一轮说明不了问题")
        window.orderOut(nil)
        return
    }
    let desktops = allSpaces().flatMap(\.spaces)
        .filter { $0.type == SkyLight.desktopSpaceType && !before.contains($0.id) }
    guard let target = requested ?? desktops.first?.id else {
        print("对照窗口 \(wid) 在 \(before)，没有别的桌面 Space 可以迁过去——先多建一个桌面")
        window.orderOut(nil)
        return
    }
    guard !before.contains(target) else {
        print("对照窗口 \(wid) 本来就在 \(target) 上，这么试什么都证明不了")
        window.orderOut(nil)
        return
    }
    print("对照窗口 \(wid)（本进程自己的）：\(before.map(String.init).joined(separator: ",")) → \(target)")
    print("  操作对象：\(Bridge.describeOperation(wid, to: target))")
    // 空转一轮：什么都不调，看它会不会自己漂过去。漂了的话下面的结果一律不算数。
    Thread.sleep(forTimeInterval: settleLimit)
    if let drifted = SkyLight.spaces(for: wid), drifted.contains(target) {
        print("  ⚠️ 什么都没调，它自己就漂到 \(target) 了——这一轮的对照不成立")
        window.orderOut(nil)
        return
    }

    for route in (via == "both" ? Bridge.routes : [via]) {
        guard let failure = Bridge.perform(route, wid, to: target) else {
            let seen = poll(wid: wid, until: target)
            print("  \(route)  \(seen.contains(target) ? "成了" : "没成")"
                  + "，归属 \(seen.map(String.init).joined(separator: ","))")
            if seen.contains(target) {
                print("→ 自家窗口迁得动。那么别人家的迁不动就是**权限**，不是调用形状。")
                window.orderOut(nil)
                return
            }
            continue
        }
        print("  \(route)  调不动：\(failure)")
    }
    print("→ 连自家窗口都迁不动。调用的形状还不对，继续查。")
    window.orderOut(nil)
}

/// 等归属连续 `stable` 不变再返回。上限 `settleLimit`。
private func settledSpaces(of wid: CGWindowID) -> [UInt64]? {
    let stable: TimeInterval = 0.5
    var last: [UInt64]?
    var since = Date()
    let deadline = Date().addingTimeInterval(settleLimit * 2)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(pollStep))
        guard let now = SkyLight.spaces(for: wid), !now.isEmpty else { continue }
        if now != last {
            last = now
            since = Date()
        } else if Date().timeIntervalSince(since) >= stable {
            return now
        }
    }
    return nil
}

private func poll(wid: CGWindowID, until target: UInt64) -> [UInt64] {
    var seen = SkyLight.spaces(for: wid) ?? []
    for _ in 0..<Int(settleLimit / pollStep) {
        RunLoop.current.run(until: Date().addingTimeInterval(pollStep))
        if let now = SkyLight.spaces(for: wid) {
            seen = now
            if now.contains(target) { break }
        }
    }
    return seen
}

/// 迁过来之后要拿得到 **AX 引用**才谈得上摆位——归属变了不等于这一步就成了。
/// 别的 Space 上的窗口根本不出现在该进程的 `AXWindows` 里（见 `Recall.swift`），
/// 所以这里量的正是「从归属变化到能写它的几何，还要等多久」。
private func report(wid: CGWindowID, activating: Bool) {
    guard let pid = enumerateCGWindows().first(where: { $0.windowID == wid })?.pid else {
        print("  AX 引用：CG 侧都找不到这个窗口了")
        return
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    if let waited = awaitElement(app, wid: wid) {
        print(String(format: "  AX 引用：归属一变就有了（%.0fms）", waited))
        return
    }
    // 归属变了不等于窗口已经上屏。真实流程里迁完紧接着就是召回，而召回会激活这个 App——
    // 所以「激活之后还取不到」才算真的取不到。
    //
    // 激活默认不做：它会把当前 Space 也切走，接着量什么都不准了。要量这一段就显式加
    // `--activate`，并且知道它有这个副作用。
    guard activating else {
        print("  AX 引用：\(Int(settleLimit * 1000))ms 内没有。"
              + "（没激活它的 App——加 --activate 量这一段，注意它会切走当前 Space）")
        return
    }
    print("  AX 引用：迁完直接取，\(Int(settleLimit * 1000))ms 内没有。激活它的 App 再试——")
    NSRunningApplication(processIdentifier: pid)?.activate()
    if let waited = awaitElement(app, wid: wid) {
        print(String(format: "  AX 引用：激活之后 %.0fms 拿到了。摆位这一步成立，"
                     + "次序是「迁 → 召回 → 等引用 → 写几何」", waited))
    } else {
        print("  AX 引用：激活之后仍然取不到。迁移成了，摆位这一步还差一环")
    }
}

/// 等这个进程的 AXWindows 里出现这扇窗口。返回等了多久（毫秒），超时返回 nil。
private func awaitElement(_ app: AXUIElement, wid: CGWindowID) -> Double? {
    let began = DispatchTime.now().uptimeNanoseconds
    let deadline = Date().addingTimeInterval(settleLimit)
    while Date() < deadline {
        let windows = axCopy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.contains(where: { windowID(of: $0).id == wid }) {
            return Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollStep))
    }
    return nil
}
