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

/// 窗口清单此刻的指纹。**只取窗口号，不建那一堆字典。**
///
/// `CGWindowListCopyWindowInfo` 每次都要为屏幕上几百个窗口各建一个字典（标题、边界、
/// 拥有者、透明度……），本机实测 4.19 毫秒；同一份名单只取窗口号是 0.09 毫秒，差四十倍。
/// 而对账绝大多数轮次什么都兜不到——那几毫秒是纯粹的空转，且它是这个进程空置时几乎
/// 全部的开销。
///
/// 两份名单都要：`optionAll` 那份认窗口的增减，上屏那份认上屏与下屏（最小化、切到别的
/// Space，在 CG 层面就是从这一份里消失）。两份都没变，对账这一轮能发现的增减就都没发生。
///
/// **它替代不了对账。** 标题与边界不在指纹里，改标题、把窗口拖到另一块屏都不会让它变——
/// 那两样归 AX 通知，以及每隔一段必来一次的那一遍完整对账（见 `World.reconcile`）。
///
/// `nil` = 这一次没读出来。调用方应当照常走完整那一遍：把「没读到」当成「没变化」，
/// 就是让兜底静悄悄地失效。
///
/// `CGWindowListCreate` 是 CoreGraphics 的公开 C 函数，只是在 Swift 里被标成不可用，
/// 因此按符号取。它与 `Private.swift` 里那些不是一回事——那些是私有 API，这个不是。
public func windowListFingerprint() -> UInt64? {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for option in [CGWindowListOption([.optionAll, .excludeDesktopElements]),
                   CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])] {
        guard let list = _CGWindowListCreate(option.rawValue, kCGNullWindowID)?
            .takeRetainedValue() else { return nil }
        // 窗口号直接存在数组的指针位里，不是 CFNumber
        for index in 0..<CFArrayGetCount(list) {
            let wid = UInt64(UInt(bitPattern: CFArrayGetValueAtIndex(list, index)))
            hash = (hash ^ wid) &* 0x0000_0100_0000_01b3
        }
        // 两份名单之间下一个分隔符，免得「A 少一个、B 多一个」互相抵消
        hash = (hash ^ 0xffff_ffff) &* 0x0000_0100_0000_01b3
    }
    return hash
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
