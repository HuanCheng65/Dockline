import AppKit
import Carbon.HIToolbox
import DocklineCore

/// 接管最大化（计划书 §3 / M4）。
///
/// 系统的 zoom 与 macOS 15 起内建的窗口拼贴都按 visibleFrame 计算，而 macOS 不向第三方
/// 开放屏幕空间预留，这类窗口一律铺到屏幕底边、压在 bar 之下。自有入口在这里：
/// 「铺满」= 可见区域再扣掉 bar 占的那一条。
final class Maximizer {
    /// 落点。可用区域整块，或把它对半切开的四种。
    ///
    /// 次序就是右键菜单里那一排图形的次序，别处不再各排一遍。
    enum Spot: CaseIterable {
        case fill, left, right, top, bottom

        /// 只用于日志。用户看到的是图形，没有文案。
        var label: String {
            switch self {
            case .fill: return "铺满"
            case .left: return "左半"
            case .right: return "右半"
            case .top: return "上半"
            case .bottom: return "下半"
            }
        }

        /// 菜单里那一排图形。这一套字形是系统自己为「窗口占屏幕的哪一块」画的，
        /// 五个的轮廓粗细与度量天生一致，自己画一套只会更差。
        var symbol: String {
            switch self {
            case .fill: return "rectangle.inset.filled"
            case .left: return "rectangle.lefthalf.inset.filled"
            case .right: return "rectangle.righthalf.inset.filled"
            case .top: return "rectangle.tophalf.inset.filled"
            case .bottom: return "rectangle.bottomhalf.inset.filled"
            }
        }

        /// 在单位矩形里占哪一块，**左上原点**（SwiftUI 系）。落点的实际矩形由它算出来。
        var unitRect: CGRect {
            switch self {
            case .fill: return CGRect(x: 0, y: 0, width: 1, height: 1)
            case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
            case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
            case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            }
        }
    }

    /// 贴过去之前的几何。还原要用，所以必须在贴过去的那一刻记下来。
    private var restore: [CGWindowID: CGRect] = [:]

    /// 有 bar 的那些屏。只有它们要扣掉 bar 的高度。
    var barDisplays: Set<CGDirectDisplayID> = []

    /// 贴到某个落点。**不做开关**：用户把格子丢到左半边，意思就是「贴到左半边」，
    /// 哪怕它已经在那儿。拖格子分屏走这条。
    ///
    /// **目标屏由调用点给，不在这里按窗口的几何去推。** 拖格子分屏问的是「指针指着
    /// 哪块屏的哪一半」，而窗口此刻可能还在另一块屏上；两边各推一次，预览飞到了 B 屏、
    /// 窗口却贴在 A 屏——实机撞到过。
    func place(_ window: IndexedWindow, at spot: Spot, on display: NSScreen) {
        guard let element = window.element else {
            Timeline.log("⚠️ 平铺跳过 wid \(window.id)：窗口在其他 Space，尚无 AX 引用")
            return
        }
        apply(element: element, name: window.appName, spot: spot, on: display, toggling: false)
    }

    /// 贴到某个落点，已经贴合就还原。右键菜单里那一排落点与快捷键走这条——
    /// 同一个记号既是「去那儿」也是「回来」，用户不必再找一个「还原」。
    ///
    /// 这条不给屏：菜单作用在窗口自己身上，没有「指针指着哪块屏」这回事，
    /// 目标就是它现在所在的那块屏。
    func toggle(_ window: IndexedWindow, at spot: Spot) {
        guard let element = window.element else {
            Timeline.log("⚠️ 平铺跳过 wid \(window.id)：窗口在其他 Space，尚无 AX 引用")
            return
        }
        guard let display = try? screen(of: element) else {
            Timeline.log("⚠️ 平铺跳过 wid \(window.id)：判不出它在哪块屏上")
            return
        }
        apply(element: element, name: window.appName, spot: spot, on: display, toggling: true)
    }

    /// 这个窗口此刻正贴在哪个落点上。都不贴合返回 nil。菜单里那一排图形据此显示选中态。
    func spot(of window: IndexedWindow) -> Spot? {
        guard let element = window.element,
              let display = try? screen(of: element),
              let current = axRect(element) else { return nil }
        return Spot.allCases.first { matchesFrame(current, flipY(rect($0, on: display))) }
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
        let element = focused as! AXUIElement
        guard let display = try? screen(of: element) else {
            Timeline.log("⚠️ 铺满跳过：判不出焦点窗口在哪块屏上")
            return
        }
        apply(element: element, name: app.localizedName ?? "?",
              spot: .fill, on: display, toggling: true)
    }

    /// 判据是当前几何是否已经贴合目标——不记开关状态。用户中途手动挪动过窗口，
    /// 下一次触发就该是重新贴过去，而不是还原到更早的位置。
    private func apply(element: AXUIElement, name: String, spot: Spot,
                       on display: NSScreen, toggling: Bool) {
        let (wid, widError) = windowID(of: element)
        guard let wid else {
            Timeline.log("⚠️ 平铺跳过 \(name)：取不到窗口号（AXError \(widError.rawValue)）")
            return
        }
        do {
            let goal = flipY(rect(spot, on: display))
            guard let current = axRect(element) else { throw FillError.noGeometry }
            if toggling, matchesFrame(current, goal),
               let saved = restore.removeValue(forKey: wid) {
                try write(element, to: saved, wid: wid, name: name, as: "还原")
                return
            }
            // 已经贴在某个落点上时不记还原点。还原要回到用户自己摆的那个位置，
            // 不是上一次贴过去的位置。
            if !onAnySpot(current, of: display) { restore[wid] = current }
            try write(element, to: goal, wid: wid, name: name, as: spot.label)
        } catch {
            Timeline.log("⚠️ 平铺失败 wid \(wid) \(name)：\(error)")
        }
    }

    private func write(_ element: AXUIElement, to destination: CGRect,
                       wid: CGWindowID, name: String, as what: String) throws {
        let outcome = try setFrame(element, to: destination)
        if outcome.fits {
            Timeline.log("\(what) wid \(wid) \(name) → \(destination)")
        } else {
            // 未贴合多半是 App 自身有尺寸约束，或它没有正确实现 AX 的位置写入。
            Timeline.log("⚠️ \(what)未贴合 wid \(wid) \(name)：目标 \(destination)，"
                         + "实际 \(outcome.after.map(String.init(describing:)) ?? "读不回")")
        }
    }

    private func onAnySpot(_ rect: CGRect, of display: NSScreen) -> Bool {
        Spot.allCases.contains { matchesFrame(rect, flipY(self.rect($0, on: display))) }
    }

    /// 落点的矩形，AppKit 坐标系。落点全部切自可用区域，因此左右两半同样不含 bar 那一条——
    /// 贴过去的窗口不会被条压住，这也是这套入口存在的理由。
    func rect(_ spot: Spot, on display: NSScreen) -> CGRect {
        let area = self.area(on: display)
        // 单位矩形是左上原点的，AppKit 是左下原点，纵向要翻过来。
        let unit = spot.unitRect
        return CGRect(x: area.minX + unit.minX * area.width,
                      y: area.maxY - unit.maxY * area.height,
                      width: unit.width * area.width,
                      height: unit.height * area.height)
    }

    /// 可用区域 = visibleFrame 再扣掉 bar 占的那一条。visibleFrame 已经排除了菜单栏，
    /// 刘海机型的菜单栏本身就高于刘海，顶边无需另算。
    private func area(on display: NSScreen) -> CGRect {
        var area = display.visibleFrame
        if let id = displayID(display), barDisplays.contains(id) {
            let barTop = display.frame.minY + BarMetrics.reservedBottom
            if area.minY < barTop {
                area.size.height -= barTop - area.minY
                area.origin.y = barTop
            }
        }
        return area
    }
}

// MARK: - 结果纠正

/// 计划书 §3「结果纠正，默认关闭」。
///
/// 系统的 zoom 与内建拼贴按 visibleFrame 计算，结果一律压在 bar 之下。这里订阅窗口的
/// 移动与尺寸变化，当新几何落在系统拼贴的落点上时，把底边抬到 bar 之上。
/// 默认关闭，因为它修改的是别的 App 的窗口。
final class TilingCorrector {
    var enabled = false
    var barDisplays: Set<CGDirectDisplayID> = []

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
    /// 用户自己把窗口放在哪儿。缩放的还原点。
    private var placed: [CGWindowID: CGRect] = [:]
    /// 纠正后写下去的矩形，按窗口。存在即表示这个窗口此刻是被纠正过的状态。
    private var corrected: [CGWindowID: CGRect] = [:]

    /// 记下窗口被发现时所在的位置。
    ///
    /// 还原要用，而窗口在第一次被缩放之前不一定发生过任何几何变化——那时订阅它的
    /// 这一刻就是唯一的记录机会。已经记过的不再读，稳态 tick 上的 AX 探测因此仍为 0。
    func note(wid: CGWindowID, element: AXUIElement) {
        guard enabled, placed[wid] == nil, let rect = axRect(element) else { return }
        placed[wid] = flipY(rect)
    }

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
              let id = displayID(display), barDisplays.contains(id) else {
            placed[wid] = frame
            corrected[wid] = nil
            return
        }
        let barTop = display.frame.minY + BarMetrics.reservedBottom
        let candidates = tilingRects(of: display)
        let onCandidate = candidates.contains { near($0, frame, within: Self.tolerance) }

        // 纠正过的窗口又落回落点，只可能是用户再次触发了缩放，而那是「还原」的意思。
        // 系统自己的还原此刻已经指望不上：底边被抬起来之后，窗口的 frame 不再等于系统
        // 认定的缩放矩形，AppKit 据此判定它没缩放过，于是再缩放一次、并把自己记的还原点
        // 覆盖成纠正后的矩形——原尺寸就此永久丢失。还原语义因此得由这里承担。
        if onCandidate, corrected[wid] != nil, let origin = placed[wid] {
            corrected[wid] = nil
            write(origin, to: element, wid: wid, as: "还原")
            return
        }
        guard onCandidate else {
            // 纠正后的位置不是用户放的，不能当作还原点
            if let goal = corrected[wid], near(goal, frame, within: Self.tolerance) { return }
            placed[wid] = frame
            corrected[wid] = nil
            if frame.minY < barTop - 1,
               let miss = candidates.first(where: { near($0, frame, within: Self.nearMiss) }) {
                Timeline.log("纠正未命中 wid \(wid)：实际 \(frame)，最近的落点 \(miss)")
            }
            return
        }
        // 底边已经在 bar 之上，没有要纠正的
        guard frame.minY < barTop - 1 else { return }

        var goal = frame
        goal.size.height -= barTop - frame.minY
        goal.origin.y = barTop
        corrected[wid] = goal
        write(goal, to: element, wid: wid, as: "纠正")
    }

    private func write(_ goal: CGRect, to element: AXUIElement, wid: CGWindowID, as what: String) {
        lastWrite[wid] = Date()
        do {
            let outcome = try setFrame(element, to: flipY(goal))
            if outcome.fits {
                Timeline.log("\(what) wid \(wid) → \(goal)")
            } else {
                // 未正确实现 AX 位置写入的 App 改不动，这是该功能的已知失败模式。
                Timeline.log("⚠️ \(what)未生效 wid \(wid)：目标 \(goal)，"
                             + "实际 \(outcome.after.map { flipY($0) }.map(String.init(describing:)) ?? "读不回")")
            }
        } catch {
            Timeline.log("⚠️ \(what)失败 wid \(wid)：\(error)")
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
