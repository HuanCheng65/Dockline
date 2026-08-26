import AppKit
import ApplicationServices

// MARK: - AX 读写小工具

public func axCopy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

public func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axCopy(element, attribute) as? Bool
}

/// 一次 IPC 往返取多个属性。逐个 AXUIElementCopyAttributeValue 每次都是一轮跨进程往返，
/// 每窗口 7 个属性即 7 轮；批量接口压成 1 轮。取不到的项返回 nil（该位置是 AXError 型 AXValue）。
public func axCopyMultiple(_ element: AXUIElement, _ attributes: [String]) -> [AnyObject?] {
    var raw: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(
        element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
    guard err == .success, let values = raw as? [AnyObject], values.count == attributes.count else {
        return Array(repeating: nil, count: attributes.count)
    }
    return values.map { value in
        // 失败位被填成 AXError 型的 AXValue，需要识别出来当作缺失
        if CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }
}

public func axRect(_ element: AXUIElement) -> CGRect? {
    guard let posValue = axCopy(element, kAXPositionAttribute),
          let sizeValue = axCopy(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

// MARK: - 索引记录

public struct WindowRecord {
    public let index: Int
    public let element: AXUIElement
    public let pid: pid_t
    public let appName: String
    public let bundleID: String?
    public let title: String?
    public let windowID: CGWindowID?          // nil = _AXUIElementGetWindow 失败
    public let widError: AXError
    public let minimized: Bool?
    public let fullscreen: Bool?
    public let frame: CGRect?
    /// AXStandardWindow / AXDialog / ... 桌面窗口无 subrole。
    /// 注意它会随状态翻转：微信主窗口活动时报 AXStandardWindow，最小化后报 AXDialog（实测 2026-08）。
    public let subrole: String?
    public let spaces: [UInt64]?              // nil = SkyLight 不可用
    /// 有没有关闭按钮。区分「窗口」与「面板」的唯一可靠判据——见 isRealWindow。
    public let closeable: Bool
}

/// 每个 regular App 的 AX 通道健康度——用来区分「这个 App 真的没窗口」和「AX 问不出来」。
public struct AppProbe {
    public let pid: pid_t
    public let name: String
    public let hidden: Bool
    public let policy: String
    public let axWindowCount: Int?    // nil = 取 kAXWindowsAttribute 出错
    public let axError: AXError
}

public struct CGWindowRecord {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect
    public let onScreen: Bool
    public let cgTitle: String?    // kCGWindowName——无屏幕录制权限时为 nil
}

// MARK: - 通道一：AX 主路

/// - Parameter pids: 只探这些进程。nil = 全部运行中 App（仅诊断用；稳态路径必须传 pid 集合，
///   因为逐 App 的 AX 调用是跨进程 IPC，全量一次约 1.9s，远超计划书 §2 的 tick 预算）。
/// - Parameter budget: 这一轮最多花多少秒。超了就把剩下的进程留给下一轮——它们不会进
///   `probes`，因此也不会被记成「判过了」，下一轮照样会探（见 `WindowIndexStore.reconcile`
///   里 `answered` 的用法）。
///
///   **有这个预算，是因为「探完为止」这个不变量的代价由别人家的 App 决定。** 无响应的
///   App 每个恰好烧满超时（本机实测 1005ms，返回 `-25204`），健康的只要 30–48ms；
///   开机时屏幕上恰好摆着几个这样的窗口，主线程就一口气堵上好几秒，看起来就是启动卡死。
///   窗口晚一拍出现，比整个界面冻住好。nil = 不设上限，只给诊断用。
public func enumerateAXWindows(pids: Set<pid_t>? = nil,
                               budget: TimeInterval? = nil)
    -> (windows: [WindowRecord], probes: [AppProbe], deferred: [pid_t]) {
    var records: [WindowRecord] = []
    var probes: [AppProbe] = []
    var deferred: [pid_t] = []
    let began = DispatchTime.now().uptimeNanoseconds
    let apps = NSWorkspace.shared.runningApplications
        .filter { pids?.contains($0.processIdentifier) ?? true }
        // .accessory 也要收：Clash Verge / OrbStack 这类菜单栏 App 一样有真窗口。
        // .prohibited 排除——XPC 服务（CursorUIViewService 等）不可能拥有真窗口。
        .filter { $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() }
        .sorted { $0.processIdentifier < $1.processIdentifier }

    for app in apps {
        let pid = app.processIdentifier
        // 预算用完了就停。判定放在每个 App 之前，不是之后：超时那一下本身就是最贵的，
        // 让它先发生再来判断，等于每一轮都白付一次。
        if let budget,
           Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9 >= budget {
            deferred.append(pid)
            continue
        }
        let axApp = AXUIElementCreateApplication(pid)
        // 不设超时会在无响应 App 上卡住默认 6 秒；1 秒足够且失败可见。
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        var raw: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw)
        let windows = raw as? [AXUIElement]
        probes.append(AppProbe(pid: pid, name: app.localizedName ?? "?", hidden: app.isHidden,
                               policy: app.activationPolicy == .regular ? "regular" : "accessory",
                               axWindowCount: windows?.count, axError: err))
        guard let windows else { continue }

        // 一次 IPC 往返取齐。加关闭按钮是免费的——它就在同一批里。
        let wanted = [kAXTitleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute,
                      "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute,
                      kAXCloseButtonAttribute]
        for window in windows {
            let (wid, widError) = windowID(of: window)
            let got = axCopyMultiple(window, wanted)

            var frame: CGRect?
            if let posValue = got[4], let sizeValue = got[5] {
                var origin = CGPoint.zero
                var size = CGSize.zero
                if AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
                   AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                    frame = CGRect(origin: origin, size: size)
                }
            }
            records.append(WindowRecord(
                index: records.count,
                element: window,
                pid: pid,
                appName: app.localizedName ?? "?",
                bundleID: app.bundleIdentifier,
                title: got[0] as? String,
                windowID: wid,
                widError: widError,
                minimized: got[2] as? Bool,
                fullscreen: got[3] as? Bool,
                frame: frame,
                subrole: got[1] as? String,
                spaces: wid.flatMap { SkyLight.spaces(for: $0) },
                closeable: got[6] != nil
            ))
        }
    }
    return (records, probes, deferred)
}

// MARK: - 通道三：CGWindowList 对账
// 计划书 §4 修订后：kCGWindowName 为跨 Space 窗口的标题主路（需屏幕录制权限，M0.5 实测覆盖率 100%）。

public func enumerateCGWindows() -> [CGWindowRecord] {
    cgWindows(.optionAll)
}

@_silgen_name("CGWindowListCreate")
private func _CGWindowListCreate(_ option: UInt32, _ relativeTo: CGWindowID) -> Unmanaged<CFArray>?

/// 窗口清单的变化哨兵：**索引会在意的那种变化，这一轮发生了没有。**
///
/// 对账要为屏幕上几百个窗口各建一个字典（标题、边界、拥有者、透明度……），本机实测
/// 4.19 毫秒，而绝大多数轮次它什么都兜不到。同一份名单只取窗口号是 0.09 毫秒，差四十倍，
/// 所以先花那 0.09 毫秒问一句「名单动了没有」，再决定要不要花那 4 毫秒去对。
///
/// 两份名单都要：`optionAll` 那份认窗口的增减，上屏那份认上屏与下屏（最小化、切到别的
/// Space，在 CG 层面就是从这一份里消失）。
///
/// **比的是集合，不是顺序。** 名单本身是 z 序的，而 z 序一天要变几百次——用户把一个
/// 窗口点到前面就变一次。对账不从 z 序推导任何东西（前台窗口走 AX 焦点，最近使用走
/// `activationClock`），按顺序比等于为一件与自己无关的事反复跑完整对账。
///
/// **layer 不为 0 的窗口一律不算数**，因为 `isCandidate` 第一条就把它们挡在外面：
/// 它们不可能进条，它们的增减对索引没有任何意义。这不是可有可无的一道过滤——
/// 我们自己的玻璃板取色每抓一次图，系统就点亮一次录屏指示灯（`StatusIndicator`，
/// layer 2147483630，每块屏一个），于是名单每两秒变一次、每两秒逼出一遍完整对账，
/// 而那遍对账每次都只能发现「什么都没变」。实测这个自激回路占掉空置开销的九成。
///
/// 消失的窗口查不到属性了，所以要记住：某个窗口号是以「不算数」的身份出现的，
/// 它消失时也不算数。不记的话只修好一半——指示灯每次**熄灭**照样触发完整对账。
///
/// `nil` = 这一次没读出来。调用方应当照常走完整那一遍：把「没读到」当成「没变化」，
/// 就是让兜底静悄悄地失效。
///
/// `CGWindowListCreate` 是 CoreGraphics 的公开 C 函数，只是在 Swift 里被标成不可用，
/// 因此按符号取。它与 `Private.swift` 里那些不是一回事——那些是私有 API，这个不是。
public final class WindowListWatch {
    private static let options: [CGWindowListOption] = [
        [.optionAll, .excludeDesktopElements],
        [.optionOnScreenOnly, .excludeDesktopElements],
    ]

    /// 上一轮的名单，以及其中「不算数」的那些。两份名单各记各的：同一个窗口可以在
    /// 全部名单里而不在上屏名单里，共用一份会让它在一边消失时把另一边的记录也抹掉。
    private var previous: [Set<CGWindowID>?]
    private var ignored: [Set<CGWindowID>]

    public init() {
        previous = Array(repeating: nil, count: Self.options.count)
        ignored = Array(repeating: [], count: Self.options.count)
    }

    public func changed() -> Bool? {
        var answer = false
        for (slot, option) in Self.options.enumerated() {
            guard let now = Self.windowList(option) else { return nil }
            defer { previous[slot] = now }
            // 头一轮没有基准，说不出变没变
            guard let before = previous[slot] else { answer = true; continue }

            let gone = before.subtracting(now)
            let unaccounted = gone.subtracting(ignored[slot])
            ignored[slot].subtract(gone)
            if !unaccounted.isEmpty { answer = true }

            let fresh = now.subtracting(before)
            guard !fresh.isEmpty else { continue }
            let layers = Self.layers(of: fresh)
            for id in fresh {
                // 查不到属性的当成算数：窗口刚生就灭也是一种变化，宁可多对一遍
                if layers[id] == 0 || layers[id] == nil { answer = true }
                else { ignored[slot].insert(id) }
            }
        }
        return answer
    }

    private static func windowList(_ option: CGWindowListOption) -> Set<CGWindowID>? {
        guard let list = _CGWindowListCreate(option.rawValue, kCGNullWindowID)?
            .takeRetainedValue() else { return nil }
        // 窗口号直接存在数组的指针位里，不是 CFNumber
        var ids = Set<CGWindowID>(minimumCapacity: CFArrayGetCount(list))
        for index in 0..<CFArrayGetCount(list) {
            ids.insert(CGWindowID(UInt(bitPattern: CFArrayGetValueAtIndex(list, index))))
        }
        return ids
    }

    /// 只问新出现的那几个窗口的 layer，一次问完。逐个问的话固定开销要付很多遍，
    /// 而指示灯的窗口号每一轮都是新的，这条路每轮都要走。
    private static func layers(of ids: Set<CGWindowID>) -> [CGWindowID: Int] {
        // 窗口号要放在数组的**指针位**里，与 `CGWindowListCreate` 返回的那种数组同形。
        // 装成 CFNumber 的话这个函数一条都查不出来，而且不报错，只是返回空数组。
        var slots = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &slots, slots.count, nil) else { return [:] }
        let described = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
        var result: [CGWindowID: Int] = [:]
        for entry in described {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let layer = entry[kCGWindowLayer as String] as? Int else { continue }
            result[id] = layer
        }
        return result
    }
}

/// 屏幕上的窗口，**从前到后**。
///
/// 必须用 `.optionOnScreenOnly`：只有这一档的返回顺序是 z 序。索引用的 `.optionAll`
/// 顺序未定义，实测与 z 序不符（前台 App 的窗口可能排在很后面）。
public func enumerateOnScreenWindowsFrontToBack() -> [CGWindowRecord] {
    cgWindows(.optionOnScreenOnly)
}

private func cgWindows(_ option: CGWindowListOption) -> [CGWindowRecord] {
    guard let raw = CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }

    return raw.compactMap { info in
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }

        return CGWindowRecord(
            windowID: wid,
            pid: pid,
            ownerName: info[kCGWindowOwnerName as String] as? String ?? "?",
            layer: layer,
            alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
            bounds: bounds,
            onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
            cgTitle: info[kCGWindowName as String] as? String
        )
    }
}

/// 关不掉的东西，用户也不需要「找回来」——面板归它的图标或父窗口管，不该单独占一格。
///
/// 判据是关闭按钮而不是 subrole，因为 subrole 在两个方向上都不成立（实测 2026-08）：
///   · Stats 的 RAM 面板报 AXStandardWindow，微信的表情面板报 AXDialog——都该踢
///   · 微信主窗口活动时报 AXStandardWindow，最小化后报 AXDialog——都该收
/// 同一对 subrole 值一收一踢，关闭按钮却把两组分得干干净净。
///
/// 最小化与全屏都不影响关闭按钮（同批实测），所以这里不需要任何状态豁免。
public func isRealWindow(_ record: WindowRecord) -> Bool {
    record.closeable
}

/// 对账口径：layer 0（普通窗口层）、非全透明、面积足够大，排除自身进程与 XPC 服务。
///
/// `.prohibited` 那条放在最后，是因为它要查进程表，前面几条都是纯算术——
/// 短路之后每轮只对几十个窗口查，不是对整张 CG 列表查。
///
/// 之所以必须在这里挡：`enumerateAXWindows` 一开头就跳过 `.prohibited`，
/// 于是它们的 pid 永远进不了「AX 枚举成功」的集合，`axSilenceIsEvidence` 那一档对它们
/// 恒为哑。不挡的话，XPC 服务名下任何 ordered-in 的 layer 0 surface 都会零检查地收进来
/// （自动填充的密码面板即属此类）。与其在准入侧留个够不着的角落，不如认下同一个断言：
/// 不能被激活的进程不可能拥有用户想找回来的窗口。
public func isCandidate(_ window: CGWindowRecord) -> Bool {
    window.layer == 0
        && window.alpha > 0.05
        && window.bounds.width >= 60 && window.bounds.height >= 60
        && window.pid != getpid()
        && NSRunningApplication(processIdentifier: window.pid)?.activationPolicy != .prohibited
}
