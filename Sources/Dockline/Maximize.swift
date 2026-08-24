import AppKit
import Carbon.HIToolbox
import DocklineCore

/// 接管最大化（计划书 §3 / M4）。
///
/// 系统的 zoom 与 macOS 15 起内建的窗口拼贴都按 visibleFrame 计算，而 macOS 不向第三方
/// 开放屏幕空间预留，这类窗口一律铺到屏幕底边、压在 bar 之下。自有入口在这里：
/// 「铺满」= 可见区域再扣掉 bar 占的那一条。
final class Maximizer {
    /// 铺满前的几何。还原要用，所以必须在铺满的那一刻记下来。
    private var restore: [CGWindowID: CGRect] = [:]

    /// bar 所在的那块屏。只有它要扣掉 bar 的高度——别的屏上 bar 不存在（多显示器见 M5）。
    var barDisplay: CGDirectDisplayID?

    /// 铺满；已经铺满则还原。
    func toggle(_ window: IndexedWindow) {
        guard let element = window.element else {
            Timeline.log("⚠️ 铺满跳过 wid \(window.id)：窗口在其他 Space，尚无 AX 引用")
            return
        }
        toggle(element: element, name: window.appName)
    }

    /// 快捷键：直接问前台 App 要焦点窗口，不查索引——索引里的前台标记是事件驱动的，
    /// 可能比按键晚一步。
    func toggleFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let focused = axCopy(axApp, kAXFocusedWindowAttribute) else {
            Timeline.log("⚠️ 铺满跳过：\(app.localizedName ?? "?") 当前没有焦点窗口")
            return
        }
        toggle(element: focused as! AXUIElement, name: app.localizedName ?? "?")
    }

    /// 铺满与还原共用一个入口，判据是当前几何是否已经贴合目标——不记开关状态。
    /// 用户中途手动挪动过窗口，下一次触发就该是铺满，而不是还原到更早的位置。
    private func toggle(element: AXUIElement, name: String) {
        let (wid, widError) = windowID(of: element)
        guard let wid else {
            Timeline.log("⚠️ 铺满跳过 \(name)：取不到窗口号（AXError \(widError.rawValue)）")
            return
        }
        do {
            let goal = target(on: try screen(of: element))
            guard let current = axRect(element) else { throw FillError.noGeometry }
            let destination: CGRect
            if matchesFrame(current, goal), let saved = restore.removeValue(forKey: wid) {
                destination = saved
            } else {
                restore[wid] = current
                destination = goal
            }
            let outcome = try setFrame(element, to: destination)
            if outcome.fits {
                Timeline.log("铺满 wid \(wid) \(name) → \(destination)")
            } else {
                // 未贴合多半是 App 自身有尺寸约束，或它没有正确实现 AX 的位置写入。
                Timeline.log("⚠️ 铺满未贴合 wid \(wid) \(name)：目标 \(destination)，"
                             + "实际 \(outcome.after.map(String.init(describing:)) ?? "读不回")")
            }
        } catch {
            Timeline.log("⚠️ 铺满失败 wid \(wid) \(name)：\(error)")
        }
    }

    /// 目标矩形。visibleFrame 已经排除了菜单栏，刘海机型的菜单栏本身就高于刘海，顶边无需另算。
    private func target(on display: NSScreen) -> CGRect {
        var area = display.visibleFrame
        if displayID(display) == barDisplay {
            let barTop = display.frame.minY + BarMetrics.reservedBottom
            if area.minY < barTop {
                area.size.height -= barTop - area.minY
                area.origin.y = barTop
            }
        }
        return flipY(area)
    }
}

/// NSScreen 对象在屏幕参数变化时会被重建，比对身份要用显示器编号。
func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

// MARK: - 结果纠正

/// 计划书 §3「结果纠正，默认关闭」。
///
/// 系统的 zoom 与内建拼贴按 visibleFrame 计算，结果一律压在 bar 之下。这里订阅窗口的
/// 移动与尺寸变化，当新几何落在系统拼贴的落点上时，把底边抬到 bar 之上。
/// 默认关闭，因为它修改的是别的 App 的窗口。
final class TilingCorrector {
    var enabled = false
    var barDisplay: CGDirectDisplayID?

    /// 等几何静止再判。拖拽改尺寸的过程中通知是连续的，逐条判会一路纠正一路打架。
    private static let settle: TimeInterval = 0.12
    /// 判据容差。系统的「拼贴的窗口带边距」设置会把落点整体内缩几个点，
    /// 严格相等会让纠正在开着边距时永远不触发——那是个静默失效。
    private static let tolerance: CGFloat = 12
    /// 近失记录的范围。落点集合目前只列了半屏与四分屏，其余形态待实测补齐（§9），
    /// 这条日志就是用来补的。
    private static let nearMiss: CGFloat = 40
    /// 自己写入后的静默期。写入本身会再触发一次移动与尺寸通知。
    private static let quiet: TimeInterval = 0.5

    private var pending: [CGWindowID: DispatchWorkItem] = [:]
    private var lastWrite: [CGWindowID: Date] = [:]

    func handle(_ element: AXUIElement) {
        guard enabled, let wid = windowID(of: element).id else { return }
        if let written = lastWrite[wid], Date().timeIntervalSince(written) < Self.quiet { return }
        pending[wid]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate(element, wid: wid) }
        pending[wid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func evaluate(_ element: AXUIElement, wid: CGWindowID) {
        pending[wid] = nil
        guard let rect = axRect(element) else { return }
        let frame = flipY(rect)                                     // AppKit 系
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              displayID(display) == barDisplay else { return }
        let barTop = display.frame.minY + BarMetrics.reservedBottom
        // 底边已经在 bar 之上，没有要纠正的
        guard frame.minY < barTop - 1 else { return }

        let candidates = tilingRects(of: display)
        guard candidates.contains(where: { near($0, frame, within: Self.tolerance) }) else {
            if let miss = candidates.first(where: { near($0, frame, within: Self.nearMiss) }) {
                Timeline.log("纠正未命中 wid \(wid)：实际 \(frame)，最近的落点 \(miss)")
            }
            return
        }

        var corrected = frame
        corrected.size.height -= barTop - frame.minY
        corrected.origin.y = barTop
        lastWrite[wid] = Date()
        do {
            let outcome = try setFrame(element, to: flipY(corrected))
            if outcome.fits {
                Timeline.log("纠正 wid \(wid) → \(corrected)")
            } else {
                // 未正确实现 AX 位置写入的 App 改不动，这是该功能的已知失败模式。
                Timeline.log("⚠️ 纠正未生效 wid \(wid)：目标 \(corrected)，"
                             + "实际 \(outcome.after.map { flipY($0) }.map(String.init(describing:)) ?? "读不回")")
            }
        } catch {
            Timeline.log("⚠️ 纠正失败 wid \(wid)：\(error)")
        }
    }

    /// 系统拼贴中会压到 bar 上的那些落点：整屏、左右半屏、下半屏、下方两个四分屏。
    /// 上半区的落点碰不到底边，进不到这里。
    private func tilingRects(of display: NSScreen) -> [CGRect] {
        let area = display.visibleFrame
        let halfW = area.width / 2
        let halfH = area.height / 2
        return [
            area,
            CGRect(x: area.minX, y: area.minY, width: halfW, height: area.height),
            CGRect(x: area.midX, y: area.minY, width: halfW, height: area.height),
            CGRect(x: area.minX, y: area.minY, width: area.width, height: halfH),
            CGRect(x: area.minX, y: area.minY, width: halfW, height: halfH),
            CGRect(x: area.midX, y: area.minY, width: halfW, height: halfH),
        ]
    }

    private func near(_ a: CGRect, _ b: CGRect, within limit: CGFloat) -> Bool {
        abs(a.minX - b.minX) < limit && abs(a.minY - b.minY) < limit
            && abs(a.maxX - b.maxX) < limit && abs(a.maxY - b.maxY) < limit
    }
}

// MARK: - 全局快捷键

/// 用 Carbon 的 RegisterEventHotKey，而不是 NSEvent 全局监听——监听器吃不掉按键，
/// 组合键会同时落到前台 App 上。
final class HotKey {
    /// 铺满 / 还原当前窗口：⌃⌥⌘F。
    static let fillKeyCode = UInt32(kVK_ANSI_F)
    static let fillModifiers = UInt32(controlKey | optionKey | cmdKey)

    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    /// 注册失败（通常是该组合已被别的程序占用）返回 nil，调用点负责让用户知道。
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4F52), id: id)   // 'MOOR'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.actions[id] = action
    }

    deinit {
        Self.actions[id] = nil
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr
            else { return OSStatus(eventNotHandledErr) }
            HotKey.actions[pressed.id]?()
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
