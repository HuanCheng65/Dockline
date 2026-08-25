import AppKit
import ApplicationServices
import DocklineCore

func pad(_ text: String, _ width: Int) -> String {
    // 中文字符终端占两列，按显示宽度补齐。
    let display = text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2000 ? 2 : 1) }
    return display >= width ? text : text + String(repeating: " ", count: width - display)
}

func axErrorName(_ error: AXError) -> String {
    switch error.rawValue {
    case 0: return "success"
    case -25200: return "failure"
    case -25201: return "illegalArgument"
    case -25202: return "invalidUIElement"
    case -25204: return "cannotComplete"
    case -25205: return "attributeUnsupported"
    case -25206: return "actionUnsupported"
    case -25211: return "apiDisabled"
    case -25212: return "noValue"
    default: return "AXError \(error.rawValue)"
    }
}

// MARK: - 焦点读取
// 两条来源，各有陷阱，实测后的结论：
//  · NSWorkspace.frontmostApplication —— 权威来源，但靠通知更新，必须跑 run loop 才会刷新。
//    在无 run loop 的 CLI 里它会一直返回进程启动那一刻的缓存值（本 spike 早期版本据此得出过错误结论）。
//  · 系统级 AX kAXFocusedApplication —— 实时，但对 Electron/Chromium 系 App（VS Code、Arc）
//    返回 nil，因其 AX 树默认惰性启用。仅作诊断参考，不作判定依据。

func focusedPIDViaAX() -> pid_t? {
    let systemWide = AXUIElementCreateSystemWide()
    guard let app = axCopy(systemWide, kAXFocusedApplicationAttribute) else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(app as! AXUIElement, &pid) == .success else { return nil }
    return pid
}

func appName(_ pid: pid_t?) -> String {
    guard let pid else { return "?" }
    return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
}

/// 判定用的权威来源。
func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

/// 两个来源并排打印——差异本身是诊断信息。
func focusReport() -> String {
    let ax = focusedPIDViaAX()
    let ws = frontmostPID()
    return "前台=\(appName(ws))(\(ws.map(String.init) ?? "—")) · [AX焦点=\(appName(ax))(\(ax.map(String.init) ?? "—"))]"
}

/// 跑 run loop 的等待——NSWorkspace 的通知才送得到。
func settle(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - 权限闸门

func requireAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        FileHandle.standardError.write("""
        docklinespike: 无辅助功能权限。
        当前进程（通常是你的终端 App，而非 docklinespike 本身）需要出现在
        系统设置 › 隐私与安全性 › 辅助功能 中并处于开启状态。
        授权后请完全退出并重开终端，再运行本命令。

        """.data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - list

func commandList() {
    if !SkyLight.available {
        print("⚠️  SkyLight 第 1 层不可用，缺失符号：\(SkyLight.missingSymbols.joined(separator: ", "))")
        print("    Space 归属列将显示为 —（降级，不影响其余功能）\n")
    }

    let started = Date()
    let (axWindows, probes) = enumerateAXWindows()
    let axElapsed = Date().timeIntervalSince(started)
    let candidates = enumerateCGWindows().filter(isCandidate)

    if let active = SkyLight.activeSpace { print("当前 Space: \(active)") }
    print("AX 窗口 \(axWindows.count) 个 · CG 候选窗口 \(candidates.count) 个 · "
          + "AX 全量枚举耗时 \(String(format: "%.0f", axElapsed * 1000))ms（\(probes.count) 个 App）\n")

    print("  \(pad("wid", 8))\(pad("App", 20)) 状态     Subrole            Space   标题")
    print("  " + String(repeating: "─", count: 86))
    for w in axWindows {
        var flags: [String] = []
        if w.minimized == true { flags.append("min") }
        if w.fullscreen == true { flags.append("full") }
        if w.windowID == nil { flags.append("NOWID:\(axErrorName(w.widError))") }
        let space = w.spaces.map { $0.map(String.init).joined(separator: "/") } ?? "—"
        let title = w.title.map { $0.isEmpty ? "(空标题)" : $0 } ?? "(AXTitle 读不到)"
        print("  \(pad(w.windowID.map(String.init) ?? "—", 8))\(pad(w.appName, 20)) \(pad(flags.isEmpty ? "-" : flags.joined(separator: ","), 8)) "
              + "\(pad(w.subrole ?? "—", 18)) \(pad(space, 7)) \(title)")
    }

    // ── App 通道健康度：区分「这个 App 真的没窗口」和「AX 问不出来」
    let cgByPID = Dictionary(grouping: candidates, by: \.pid)
    print("\n── App 通道 ──────────────────────────────────────────────────────────")
    print("  \(pad("App", 20)) \(pad("pid", 8)) \(pad("policy", 10)) \(pad("AX 窗口", 10)) \(pad("hidden", 8)) CG 大窗口(≥300²)")
    for probe in probes.sorted(by: { $0.name < $1.name }) {
        let big = cgByPID[probe.pid]?.filter { $0.bounds.width >= 300 && $0.bounds.height >= 300 }.count ?? 0
        let ax = probe.axWindowCount.map(String.init) ?? "✗ \(axErrorName(probe.axError))"
        let cols = [pad(probe.name, 20), pad("\(probe.pid)", 8), pad(probe.policy, 10),
                    pad(ax, 10), pad(probe.hidden ? "yes" : "-", 8), "\(big)"]
        print("  " + cols.joined(separator: " "))
    }

    // ── 对账
    let axIDs = Set(axWindows.compactMap(\.windowID))
    let blind = candidates.filter { !axIDs.contains($0.windowID) }
    let bigBlind = blind.filter { $0.bounds.width >= 300 && $0.bounds.height >= 300 }

    // 判别式：ordered-in 才是真窗口。被 orderOut: 关掉的窗口对象仍在、仍有 Space 归属，
    // 但已移出显示列表；而位于其他 Space 的真窗口依然 ordered-in。
    struct Classified {
        let window: CGWindowRecord
        let spaces: [UInt64]
        let orderedIn: Bool?
    }
    let classified = bigBlind.map {
        Classified(window: $0, spaces: SkyLight.spaces(for: $0.windowID) ?? [], orderedIn: SkyLight.isOrderedIn($0.windowID))
    }
    let probeFailed = classified.filter { $0.orderedIn == nil }
    let realBlind = classified.filter { $0.orderedIn == true }
    let zombies = classified.filter { $0.orderedIn == false }
    let noWID = axWindows.filter { $0.windowID == nil }

    print("\n── 对账 ──────────────────────────────────────────────────────────────")
    print("  CG 候选 \(candidates.count) · 被 AX 覆盖 \(candidates.count - blind.count) · AX 盲区 \(blind.count)")
    print("  盲区拆解：<300² 噪声 \(blind.count - bigBlind.count) · ordered-out 僵尸 surface \(zombies.count) · "
          + "★ ordered-in 真盲区窗口 \(realBlind.count)"
          + (probeFailed.isEmpty ? "" : " · ⚠️ ordered-in 探测失败 \(probeFailed.count)"))
    print("  AX 有窗口但取不到 WindowID: \(noWID.count)")

    if !noWID.isEmpty {
        print("\n  取不到 WindowID 的 AX 窗口：")
        for w in noWID {
            print("    #\(w.index) \(w.appName) — subrole=\(w.subrole ?? "—") — \(axErrorName(w.widError))")
        }
    }
    if !bigBlind.isEmpty {
        print("\n  ≥300² 的 AX 盲区窗口（★ = ordered-in，判定为真窗口）：")
        for entry in classified.sorted(by: { $0.window.ownerName < $1.window.ownerName }) {
            let mark = entry.orderedIn == nil ? "?" : (entry.orderedIn! ? "★" : " ")
            let space = entry.spaces.isEmpty ? "无" : entry.spaces.map(String.init).joined(separator: "/")
            let size = "\(Int(entry.window.bounds.width))×\(Int(entry.window.bounds.height))"
            let alpha = String(format: "%.2f", entry.window.alpha)
            let cols = ["wid " + pad("\(entry.window.windowID)", 7), pad(entry.window.ownerName, 18),
                        "pid " + pad("\(entry.window.pid)", 7), pad(size, 10),
                        "Space=" + pad(space, 6), "alpha=" + alpha]
            print("    \(mark) " + cols.joined(separator: " "))
        }
    }
}

// MARK: - index（bar 实际使用的合并索引——与 App 共用同一份 DocklineCore 实现）

func commandIndex() {
    var timing = IndexTiming()
    var rejections: [IndexRejection] = []
    let windows = buildWindowIndex(timing: &timing, rejections: &rejections)
    // 首次调用含 dlopen / AX 连接建立的一次性开销，再测一次看稳态
    var warm = IndexTiming()
    _ = buildWindowIndex(timing: &warm)

    print("当前 Space: \(SkyLight.activeSpace.map(String.init) ?? "—")")
    print(String(format: "合并索引 %d 个窗口 · 被否决候选 %d 个", windows.count, rejections.count))
    print(String(format: "  首次: 总 %.1fms（CG 列表 %.1f · AX 探测 %.1f · ordered-in %.1f）",
                 timing.total, timing.cgList, timing.axProbe, timing.orderedIn))
    print(String(format: "  稳态: 总 %.1fms（CG 列表 %.1f · AX 探测 %.1f · ordered-in %.1f）\n",
                 warm.total, warm.cgList, warm.axProbe, warm.orderedIn))
    let layout = DisplayLayout.current()
    print("显示器: " + layout.displays.map {
        "\($0.id) \(Int($0.frame.width))×\(Int($0.frame.height))@(\(Int($0.frame.minX)),\(Int($0.frame.minY)))"
    }.joined(separator: " · "))
    print("  \(pad("wid", 8))\(pad("App", 18))\(pad("来源", 8))\(pad("状态", 8))\(pad("Space", 8))\(pad("屏", 12))标题")
    print("  " + String(repeating: "─", count: 96))
    for w in windows {
        var flags: [String] = []
        if w.minimized { flags.append("min") }
        if w.fullscreen { flags.append("full") }
        let source = w.source == .ax ? "AX" : "CG-only"
        let space = w.spaces.isEmpty ? "—" : w.spaces.map(String.init).joined(separator: "/")
        let display = w.display.map(String.init) ?? "判不出"
        let cols = [pad("\(w.id)", 8), pad(w.appName, 18), pad(source, 8),
                    pad(flags.isEmpty ? "-" : flags.joined(separator: ","), 8), pad(space, 8),
                    pad(display, 12), w.title]
        print("  " + cols.joined())
    }
    if !rejections.isEmpty {
        print("\n  被否决的 CG 候选窗口（尺寸已过 120² 这关）：")
        print("  \(pad("wid", 8))\(pad("App", 18))\(pad("尺寸", 12))\(pad("ordered-in", 12))\(pad("subrole", 20))原因")
        for r in rejections.sorted(by: { $0.app < $1.app }) {
            let size = "\(Int(r.size.width))×\(Int(r.size.height))"
            let ordered = r.orderedIn.map(String.init) ?? "探测失败"
            let sub = r.hasAX ? (r.subrole ?? "—") : "(无 AX 记录)"
            print("  " + [pad("\(r.id)", 8), pad(r.app, 18), pad(size, 12),
                          pad(ordered, 12), pad(sub, 20), r.reason].joined())
        }
    }

    let cgOnly = windows.filter { $0.source == .cgOnly }
    if !cgOnly.isEmpty {
        print("\n  其中 \(cgOnly.count) 个来自其他 Space（无 AX 引用，点击走激活 App 粗路认领）")
    }
}

// MARK: - bench（M0.5：为「后台轻量」约束与屏幕录制权限决策提供数据）

func commandBench() {
    let granted = CGPreflightScreenCaptureAccess()
    print("── 权限 ──────────────────────────────────────────────────────────────")
    print("  屏幕录制权限: \(granted ? "已授权 ✓" : "未授权 ✗（CG 标题会被静默抹成 nil，覆盖率测不准）")")
    if !granted {
        print("  注意：权限要授给**宿主进程**（你的终端 / VS Code），不是 docklinespike 本身。")
    }

    // ── 通道成本
    print("\n── 通道成本（稳态轮询要反复付的）────────────────────────────────────")
    var cgTimes: [Double] = []
    var lastList: [CGWindowRecord] = []
    for _ in 1...10 {
        let t0 = Date()
        lastList = enumerateCGWindows()
        cgTimes.append(Date().timeIntervalSince(t0) * 1000)
    }
    let candidates = lastList.filter(isCandidate)
    print(String(format: "  CGWindowListCopyWindowInfo(.optionAll) ×10: 平均 %.2fms · 最小 %.2fms · 最大 %.2fms（%d 个窗口）",
                 cgTimes.reduce(0,+)/10, cgTimes.min()!, cgTimes.max()!, lastList.count))

    let ids = candidates.map(\.windowID)
    let t1 = Date()
    for id in ids { _ = SkyLight.isOrderedIn(id) }
    let orderedMs = Date().timeIntervalSince(t1) * 1000
    let t2 = Date()
    for id in ids { _ = SkyLight.spaces(for: id) }
    let spacesMs = Date().timeIntervalSince(t2) * 1000
    print(String(format: "  SLSWindowIsOrderedIn ×%d: 总 %.2fms（平均 %.0fµs/次）", ids.count, orderedMs, orderedMs * 1000 / Double(ids.count)))
    print(String(format: "  SLSCopySpacesForWindows ×%d: 总 %.2fms（平均 %.0fµs/次）", ids.count, spacesMs, spacesMs * 1000 / Double(ids.count)))
    print(String(format: "  ⇒ 一次完整对账 tick ≈ %.1fms", cgTimes.reduce(0,+)/10 + orderedMs + spacesMs))

    let t3 = Date()
    let (axWindows, probes) = enumerateAXWindows()
    print(String(format: "  （对照）AX 全量枚举: %.0fms / %d 个 App —— 仅冷启动付一次", Date().timeIntervalSince(t3) * 1000, probes.count))

    // ── 标题覆盖率：决定屏幕录制权限能否取代标题缓存
    print("\n── 标题覆盖率（AX 标题 vs CG 标题）──────────────────────────────────")
    let realWindows = candidates.filter { SkyLight.isOrderedIn($0.windowID) == true }
    let axTitleByID = Dictionary(axWindows.compactMap { w -> (CGWindowID, String)? in
        guard let id = w.windowID, let title = w.title else { return nil }
        return (id, title)
    }, uniquingKeysWith: { a, _ in a })

    print("  \(pad("wid", 8))\(pad("App", 18))\(pad("AX 标题", 30))CG 标题")
    var cgHas = 0
    for w in realWindows.sorted(by: { $0.ownerName < $1.ownerName }) {
        let ax = axTitleByID[w.windowID]
        let cg = w.cgTitle
        if !(cg ?? "").isEmpty { cgHas += 1 }
        print("  \(pad("\(w.windowID)", 8))\(pad(w.ownerName, 18))"
              + "\(pad(ax.map { $0.isEmpty ? "(空)" : $0 } ?? "—(无 AX 引用)", 30))"
              + "\(cg.map { $0.isEmpty ? "(空)" : $0 } ?? "—(nil)")")
    }
    print("  ⇒ ordered-in 真窗口 \(realWindows.count) 个，其中有 CG 标题的 \(cgHas) 个"
          + String(format: "（覆盖率 %.0f%%）", realWindows.isEmpty ? 0 : Double(cgHas) / Double(realWindows.count) * 100))

    // ── 最小化窗口的 ordered-in 状态：检验 AX ∪ CG 并集是否闭合
    print("\n── 最小化窗口（检验 AX ∪ CG 并集是否有洞）──────────────────────────")
    let minimized = axWindows.filter { $0.minimized == true }
    if minimized.isEmpty {
        print("  当前无最小化窗口——请最小化一个窗口后重跑此项")
    }
    for w in minimized {
        guard let id = w.windowID else { print("  \(w.appName): 无 wid"); continue }
        let inCG = candidates.contains { $0.windowID == id }
        // 最小化窗口在 AX 里必然存在（第 2 节已验证跨 Space 也在），故并集恒覆盖；
        // 这里要看的是 CG 侧会不会漏——若漏，说明纯 CG 方案单独用不了。
        print("  \(w.appName) — \(w.title ?? "?"): ordered-in=\(SkyLight.isOrderedIn(id).map(String.init) ?? "?") "
              + "· 在 CG 候选里=\(inCG ? "是" : "否 ← 纯 CG 方案会漏掉它") · 在 AX 里=是")
    }
}

// MARK: - raise

func commandRaise(_ wid: CGWindowID) {
    guard let w = enumerateAXWindows().windows.first(where: { $0.windowID == wid }) else {
        FileHandle.standardError.write("docklinespike: wid \(wid) 不在 AX 索引里，先跑 `docklinespike list`\n".data(using: .utf8)!)
        exit(1)
    }
    print("召回 wid \(wid) \(w.appName) — \(w.title ?? "?")"
          + "  [min=\(w.minimized.map(String.init) ?? "?") full=\(w.fullscreen.map(String.init) ?? "?")"
          + " space=\(w.spaces?.map(String.init).joined(separator: "/") ?? "—")]")

    let outcome = raiseWindow(w)
    if let unminimize = outcome.unminimize { print("  取消最小化: \(axErrorName(unminimize))") }
    print("  AXRaise: \(axErrorName(outcome.raise))")
    print("  activate: \(outcome.activated)")

    settle(0.8)   // 等系统跑完 Space 切换 / 取消最小化动画再回读
    print("  结果: \(focusReport()) \(frontmostPID() == w.pid ? "✓" : "✗ 目标 pid \(w.pid)")")
    if let space = SkyLight.activeSpace { print("        当前 Space = \(space)") }
    if let again = enumerateAXWindows().windows.first(where: { $0.windowID != nil && $0.windowID == w.windowID }) {
        print("        回读该窗口: min=\(again.minimized.map(String.init) ?? "?") frame=\(again.frame.map(String.init(describing:)) ?? "?")")
    }
}

// MARK: - hold-raise（§4 常规路径：手持既有 AX 引用，召回已跑到其他 Space 的窗口）
// 这是 M1 最高频的交互：bar 存着早先抓到的引用，用户在别的 Space 上点格子。
// 本 spike 每次调用都重新枚举，而枚举只返回当前 Space，所以必须靠「先抓引用再等你切走」来构造。

func commandHoldRaise(_ wid: CGWindowID) {
    guard let w = enumerateAXWindows().windows.first(where: { $0.windowID == wid }) else {
        FileHandle.standardError.write("docklinespike: wid \(wid) 不在 AX 索引里\n".data(using: .utf8)!)
        exit(1)
    }
    print("已抓住 wid \(wid) \(w.appName) — \(w.title ?? "?") 的 AX 引用")
    print("  抓取时: Space \(w.spaces?.map(String.init).joined(separator: "/") ?? "—") · "
          + "min=\(w.minimized.map(String.init) ?? "?") · full=\(w.fullscreen.map(String.init) ?? "?")")
    print("\n  ▶ 现在请切到另一个 Space（⌃→ / 触控板三指左右滑），5 秒后自动召回…")
    for remaining in stride(from: 5, through: 1, by: -1) {
        print("    \(remaining)…")
        usleep(1_000_000)
    }

    let spaceBefore = SkyLight.activeSpace
    print("\n  召回前: 当前 Space \(spaceBefore.map(String.init) ?? "—")")

    // 引用是否还活着——直接拿它读一次标题。
    let titleNow = axCopy(w.element, kAXTitleAttribute) as? String
    print("  引用存活检查: 读标题 = \(titleNow.map { "\"\($0)\"" } ?? "✗ 读不到（引用可能已失效）")")

    if axBool(w.element, kAXMinimizedAttribute) == true {
        let err = AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        print("  取消最小化: \(axErrorName(err))")
    }
    let raiseErr = AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    print("  AXRaise: \(axErrorName(raiseErr))")
    if let app = NSRunningApplication(processIdentifier: w.pid) {
        print("  activate: \(app.activate() ? "true" : "false")")
    }

    settle(1.5)
    let spaceAfter = SkyLight.activeSpace
    let spaceMoved = spaceBefore != spaceAfter
    print("  结果: \(focusReport()) \(frontmostPID() == w.pid ? "✓" : "✗ 目标 \(w.appName)")")
    print("        当前 Space = \(spaceAfter.map(String.init) ?? "—") \(spaceMoved ? "（已跨 Space 切换）" : "（未切换）")")
    let backInAX = enumerateAXWindows().windows.contains { $0.windowID == wid }
    print("        该窗口回到当前 Space 的 AX 列表: \(backInAX ? "是 ✓" : "否 ✗")")
}

// MARK: - roundtrip（跨 Space + 全屏窗口的自动往返）
// 全屏窗口独占一个 Space，而终端在另一个 Space，人手切换构造不出「持旧引用召回」的场景。
// 这里由程序完成往返：激活目标 → 抓引用 → 激活回原 App（离开该 Space）→ 用旧引用召回。

func commandRoundtrip(_ pid: pid_t, preferredWID: CGWindowID?) {
    guard let target = NSRunningApplication(processIdentifier: pid) else {
        FileHandle.standardError.write("docklinespike: pid \(pid) 不是运行中的 App\n".data(using: .utf8)!)
        exit(1)
    }
    guard let origin = NSWorkspace.shared.frontmostApplication else {
        FileHandle.standardError.write("docklinespike: 读不到当前前台 App\n".data(using: .utf8)!)
        exit(1)
    }
    print("往返测试: \(origin.localizedName ?? "?") → \(target.localizedName ?? "?") → \(origin.localizedName ?? "?") → 用旧引用召回")
    print("  起点 Space \(SkyLight.activeSpace.map(String.init) ?? "—") · \(focusReport())")

    print("\n  ① 激活 \(target.localizedName ?? "?") 并抓引用: \(target.activate() ? "true" : "false")")
    settle(1.5)
    let candidates = enumerateAXWindows().windows.filter { $0.pid == pid }
    // 优先真窗口（AXStandardWindow + 有标题），避免抓到 Arc 那类空标题临时覆盖层。
    let real = candidates.filter { $0.subrole == "AXStandardWindow" && !($0.title ?? "").isEmpty }
    guard let w = candidates.first(where: { $0.windowID == preferredWID })
            ?? real.first(where: { $0.fullscreen == true })
            ?? real.first
            ?? candidates.first else {
        FileHandle.standardError.write("docklinespike: 激活后 \(target.localizedName ?? "?") 仍无 AX 窗口\n".data(using: .utf8)!)
        exit(1)
    }
    print("     抓到 wid \(w.windowID.map(String.init) ?? "—") · full=\(w.fullscreen.map(String.init) ?? "?") "
          + "· Space \(w.spaces?.map(String.init).joined(separator: "/") ?? "—") · \(w.title ?? "(无标题)")")

    print("\n  ② 激活回 \(origin.localizedName ?? "?") 以离开该 Space: \(origin.activate() ? "true" : "false")")
    settle(2.0)
    let spaceAway = SkyLight.activeSpace
    print("     现在 Space \(spaceAway.map(String.init) ?? "—")")
    let stillListed = enumerateAXWindows().windows.contains { $0.windowID == w.windowID }
    print("     该窗口是否还在 AX 枚举结果里: \(stillListed ? "是" : "否（已离开当前 Space，符合预期）")")

    print("\n  ③ 用手里的旧引用召回")
    let titleNow = axCopy(w.element, kAXTitleAttribute) as? String
    print("     引用存活检查: 读标题 = \(titleNow.map { "\"\($0)\"" } ?? "✗ 读不到（引用已失效）")")
    let raiseErr = AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    print("     AXRaise: \(axErrorName(raiseErr))")
    print("     activate: \(target.activate() ? "true" : "false")")

    print("     焦点采样（每 500ms）:")
    var focusHit = false
    for tick in 1...8 {
        settle(0.5)
        let hit = frontmostPID() == pid
        if hit { focusHit = true }
        print("       \(String(format: "%.1f", Double(tick) * 0.5))s: \(focusReport()) "
              + "\(hit ? "✓" : "") · Space \(SkyLight.activeSpace.map(String.init) ?? "—")")
        if hit { break }
    }
    let spaceBack = SkyLight.activeSpace
    print("     结果: 焦点\(focusHit ? "已转移到目标 ✓" : "始终未转移到目标 ✗")")
    print("           当前 Space = \(spaceBack.map(String.init) ?? "—") "
          + "\(spaceBack != spaceAway ? "（已跨 Space 切回）" : "（未切换 ✗）")")
    let backInAX = enumerateAXWindows().windows.contains { $0.windowID == w.windowID }
    print("           该窗口回到 AX 列表: \(backInAX ? "是 ✓" : "否 ✗")")
}

// MARK: - activate（§4 粗路：跨 Space 存量窗口靠激活 App 认领）

func commandActivate(_ pid: pid_t) {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        FileHandle.standardError.write("docklinespike: pid \(pid) 不是运行中的 App\n".data(using: .utf8)!)
        exit(1)
    }
    let before = enumerateAXWindows().windows.filter { $0.pid == pid }
    print("激活 \(app.localizedName ?? "?") (pid \(pid))")
    print("  激活前: AX 窗口 \(before.count) 个 · 当前 Space \(SkyLight.activeSpace.map(String.init) ?? "—")")
    print("  activate: \(app.activate() ? "true" : "false")")

    settle(1.5)   // Space 切换动画约 0.5–1s，留足余量再补抓
    let after = enumerateAXWindows().windows.filter { $0.pid == pid }
    print("  激活后: AX 窗口 \(after.count) 个 · 当前 Space \(SkyLight.activeSpace.map(String.init) ?? "—")")
    for w in after {
        let space = w.spaces?.map(String.init).joined(separator: "/") ?? "—"
        print("    wid \(w.windowID.map(String.init) ?? "—") · Space \(space) · "
              + "full=\(w.fullscreen.map(String.init) ?? "?") · \(w.title ?? "(无标题)")")
    }
    let gained = after.compactMap(\.windowID).filter { id in !before.compactMap(\.windowID).contains(id) }
    print("  结论: \(gained.isEmpty ? "未补抓到新的 AX 引用" : "补抓到 \(gained.count) 个新 AX 引用 ✓ \(gained)")")
}

// MARK: - fill（接管最大化：铺满 visibleFrame）

func commandFill(_ wid: CGWindowID) {
    guard let w = enumerateAXWindows().windows.first(where: { $0.windowID == wid }) else {
        FileHandle.standardError.write("docklinespike: wid \(wid) 不在 AX 索引里\n".data(using: .utf8)!)
        exit(1)
    }
    // spike 不含 bar，目标就是整块 visibleFrame（本体还要再扣掉 bar 那一条）。
    let outcome: FillOutcome
    let display: NSScreen
    do {
        display = try screen(of: w.element)
        outcome = try setFrame(w.element, to: flipY(display.visibleFrame))
    } catch {
        FileHandle.standardError.write("docklinespike: wid \(wid) 铺满失败 —— \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    print("铺满 wid \(wid) \(w.appName) — \(w.title ?? "?")")
    print("  屏幕 \(display.localizedName) · visibleFrame(AX 系) = \(outcome.target)")
    print("  写入前 \(outcome.before)")
    for (i, pass) in outcome.passes.enumerated() {
        print("  第 \(i + 1) 遍: position \(axErrorName(pass.position)) · size \(axErrorName(pass.size))")
    }
    let after = outcome.after.map(String.init(describing:)) ?? "读不回"
    print("  写入后 \(after)" + (outcome.fits ? " ✓" : " ✗ 未贴合"))
}


// MARK: - events（窗口服务器通知的实测。调度中心让位就是靠这里认出来的事件号）

/// 在一段号码区间上都挂一个观察者，把收到的事件按时间打出来。
///
/// 存在的理由：这族通知没有公开清单，事件号只能靠「做一个动作，看谁响了」定出来。
/// 一次只认一个号码是不够的——要区分「只在调度中心响」和「别的动作也响」，
/// 必须同时盯住一整段，再用时间戳去对齐动作。
func commandEvents(from first: UInt32, to last: UInt32, seconds: Double) {
    let start = Date()
    let proc: SkyLight.NotifyProc = { type, _, _, _ in
        let stamp = Date().timeIntervalSince(eventsStart)
        print(String(format: "%8.3fs  事件 %d", stamp, type))
        fflush(stdout)
    }
    eventsStart = start
    var registered = 0
    for type in first...last where SkyLight.onEvent(type, context: nil, proc) { registered += 1 }
    guard registered > 0 else {
        FileHandle.standardError.write("SLSRegisterNotifyProc 不可用\n".data(using: .utf8)!)
        exit(1)
    }
    print("盯住事件 \(first)–\(last)（共 \(registered) 个），\(Int(seconds)) 秒后退出。")
    print("现在去做要测的动作，每做一个隔两三秒，方便按时间戳分段。\n")
    fflush(stdout)
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
    // 必须跑 NSApplication 的事件循环。这族通知经窗口服务器连接的事件队列投递，
    // 裸 RunLoop 不泵它——实测挂着 401 个观察者 45 秒，一个事件都收不到。
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
}

/// 回调是 C 函数指针，捕获不了局部变量，起始时刻只能走全局。
var eventsStart = Date()

// MARK: - mc（调度中心的确认判据）
//
// 1327 / 1328 不是「调度中心开 / 关」，实测最小化与取消最小化也发同一对（见计划书 §8）。
// 于是判据要从「信号说它开了」改成「看见它确实开着」。这个命令量的就是那个「看见」：
// 收到 1327 之后，程序坞那张铺满屏的 surface 多久出现、长什么样。

func commandMissionControl(seconds: Double) {
    let proc: SkyLight.NotifyProc = { type, _, _, _ in
        let stamp = Date().timeIntervalSince(eventsStart)
        guard type == 1327 else {
            print(String(format: "%8.3fs  1328（转场结束）", stamp))
            fflush(stdout)
            return
        }
        print(String(format: "%8.3fs  1327（转场开始），开始逐 20ms 采样 ——", stamp))
        fflush(stdout)
        sampleDockSurface(round: 0, since: Date())
    }
    eventsStart = Date()
    guard SkyLight.onEvent(1327, context: nil, proc), SkyLight.onEvent(1328, context: nil, proc) else {
        FileHandle.standardError.write("SLSRegisterNotifyProc 不可用\n".data(using: .utf8)!)
        exit(1)
    }
    print("盯住 1327 / 1328，\(Int(seconds)) 秒后退出。")
    fflush(stdout)
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
}

/// 采样上限：30 轮 × 20ms = 600ms。调度中心的开场动画约 300–400ms，留一倍余量。
private func sampleDockSurface(round: Int, since: Date) {
    guard round < 30 else {
        print("          —— 600ms 内没等到铺满屏的程序坞 surface\n")
        fflush(stdout)
        return
    }
    let screens = NSScreen.screens.map { flipY($0.frame) }
    // 按 pid 认程序坞。`ownerName` 是本地化的（中文系统上是「程序坞」），按名字认会随语言失效。
    let dock = NSRunningApplication
        .runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    let hits = enumerateCGWindows().filter { window in
        // onScreen 必须要：程序坞常年挂着一张同样铺满屏、但 ordered-out 的 surface
        window.pid == dock && window.onScreen && screens.contains { screen in
            window.bounds.width >= screen.width - 1 && window.bounds.height >= screen.height - 1
        }
    }
    guard !hits.isEmpty else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            sampleDockSurface(round: round + 1, since: since)
        }
        return
    }
    let delay = Date().timeIntervalSince(since) * 1000
    print(String(format: "          +%.0fms  找到 %d 张：", delay, hits.count))
    for hit in hits {
        print("            wid \(hit.windowID)  layer \(hit.layer)  alpha \(hit.alpha)"
              + "  \(Int(hit.bounds.width))×\(Int(hit.bounds.height))"
              + "@(\(Int(hit.bounds.minX)),\(Int(hit.bounds.minY)))"
              + "  onScreen=\(hit.onScreen)  标题=\(hit.cgTitle ?? "—")")
    }
    print("")
    fflush(stdout)
}

// MARK: - 入口

let arguments = Array(CommandLine.arguments.dropFirst())
requireAccessibility()

switch arguments.first {
case "list", nil:
    commandList()
case "bench":
    commandBench()
case "index":
    commandIndex()
case "probe":
    var after: Double = 0
    var minimum: CGFloat = 120
    var rest = Array(arguments.dropFirst())
    while let flag = rest.first {
        rest.removeFirst()
        guard let value = rest.first.flatMap(Double.init) else {
            FileHandle.standardError.write("用法: docklinespike probe [--after 秒] [--min 边长]\n".data(using: .utf8)!)
            exit(1)
        }
        rest.removeFirst()
        switch flag {
        case "--after": after = value
        case "--min": minimum = CGFloat(value)
        default:
            FileHandle.standardError.write("probe: 无法识别的选项 \(flag)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    commandProbe(after: after, minimumSize: minimum)
case "events":
    let rest = Array(arguments.dropFirst())
    let first = rest.first.flatMap(UInt32.init) ?? 1200
    let last = rest.dropFirst().first.flatMap(UInt32.init) ?? 1600
    let seconds = rest.dropFirst(2).first.flatMap(Double.init) ?? 60
    commandEvents(from: first, to: last, seconds: seconds)
case "mc":
    commandMissionControl(seconds: arguments.dropFirst().first.flatMap(Double.init) ?? 30)
case "keytap":
    let rest = Array(arguments.dropFirst())
    commandKeyTap(seconds: rest.first.flatMap(Double.init) ?? 60,
                  stalls: rest.contains("--stall"))
case "activate":
    guard let p = arguments.dropFirst().first.flatMap(Int32.init) else {
        FileHandle.standardError.write("用法: docklinespike activate <pid>\n".data(using: .utf8)!)
        exit(1)
    }
    commandActivate(p)
case "roundtrip":
    guard let p = arguments.dropFirst().first.flatMap(Int32.init) else {
        FileHandle.standardError.write("用法: docklinespike roundtrip <pid> [wid]\n".data(using: .utf8)!)
        exit(1)
    }
    commandRoundtrip(p, preferredWID: arguments.dropFirst(2).first.flatMap(CGWindowID.init))
case "hold-raise":
    guard let wid = arguments.dropFirst().first.flatMap(CGWindowID.init) else {
        FileHandle.standardError.write("用法: docklinespike hold-raise <wid>\n".data(using: .utf8)!)
        exit(1)
    }
    commandHoldRaise(wid)
case "raise", "fill":
    guard let wid = arguments.dropFirst().first.flatMap(CGWindowID.init) else {
        FileHandle.standardError.write("用法: docklinespike \(arguments[0]) <wid>\n".data(using: .utf8)!)
        exit(1)
    }
    arguments[0] == "raise" ? commandRaise(wid) : commandFill(wid)
default:
    print("用法: docklinespike [list | index | bench | events [起 止 秒] | keytap [秒] [--stall]"
          + " | raise <wid> | fill <wid> | hold-raise <wid> | activate <pid> | roundtrip <pid> [wid]]")
}
