import AppKit
import DocklineCore

// MARK: - spaces —— Space 归属与转场的只读诊断
//
// 要回答的问题只有一个：**系统程序坞凭什么在桌面之间滑动时钉住不动，进出全屏时又跟着
// 桌面一起滑走**。我们自己的 BarPanel 配的是 `.canJoinAllSpaces + .stationary`，
// 表现是两种转场都跟着桌面横向走。差别一定落在窗口服务器那一侧，所以把三方摊开对比：
// 系统程序坞、系统菜单栏、我们自己的 bar，逐位 diff。
//
// 这个命令存在的理由是**不照抄社区常量**。社区流传的 `kCGSSuperStickyTagBit` 一类名字
// 在本机没有对应物：程序坞身上根本没有 all-workspaces 那一位。该设哪些位、要不要动
// Space 归属，得由这里的读数决定。
//
//   docklinespike spaces [--wid n]…             一次快照：Space 拓扑 + 三方画像 + 逐位 diff
//   docklinespike spaces --watch 秒 [--hz N]     转场期间连续采样：谁在动、动多少
//
// 全程只读：只调 Get / Copy 族，不写 tag、不动 Space 归属。

/// 程序坞 UI 那张窗口的 level（`NSWindow.Level.dock`）。程序坞名下还挂着每个 Space
/// 一张的壁纸窗口，它们在极低的 level 上——diff 要的不是它们。
private let dockUILevel = 20

/// 菜单栏的几何判据：与某块屏等宽、贴着屏顶、不高。
/// 不按 `ownerName` 认，那个名字是本地化的（中文系统上程序坞叫「程序坞」）。
private let menuBarMaxHeight: CGFloat = 60

// MARK: - 取窗口

/// 窗口全量列表，**不加** `.excludeDesktopElements`。
///
/// 共用的 `enumerateCGWindows()` 带着那个排除项，正好把这里最要看的东西滤掉了：
/// 程序坞名下每个 Space 一张的壁纸窗口。壁纸是「谁按 Space 摆一份」的活证据，不能丢。
private struct RawWindow {
    let wid: CGWindowID
    let pid: pid_t
    let owner: String
    let layer: Int
    let bounds: CGRect
    let onScreen: Bool
}

private func allWindowsIncludingDesktop() -> [RawWindow] {
    guard let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    return raw.compactMap { info in
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              let dict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return RawWindow(wid: wid, pid: pid,
                         owner: info[kCGWindowOwnerName as String] as? String ?? "?",
                         layer: layer, bounds: bounds,
                         onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

/// 一条窗口画像：CG 侧的几何与 layer，加上窗口服务器侧的 tag / level / Space 归属。
private struct Portrait {
    let group: String
    let window: RawWindow
    let serverLevel: Int32?
    let tags: UInt64?
    let spaces: [UInt64]
    let orderedIn: Bool?

    var bits: [Int] { tags.map { t in (0..<64).filter { t >> $0 & 1 == 1 } } ?? [] }
}

private func portrait(_ group: String, _ window: RawWindow) -> Portrait {
    Portrait(group: group, window: window,
             serverLevel: SkyLight.windowLevel(of: window.wid),
             tags: SkyLight.windowTags(of: window.wid),
             spaces: SkyLight.spaces(for: window.wid) ?? [],
             orderedIn: SkyLight.isOrderedIn(window.wid))
}

/// 上一次收窗口时，几何像菜单栏但已 ordered-out 的 surface 有几张。只为报数。
private var skippedMenuBarSurfaces = 0

private func pid(ofBundle id: String) -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier
}

/// 三方 + 手工指定的窗口，按组收齐。顺序即打印顺序。
private func interestingWindows(extra: [CGWindowID]) -> [Portrait] {
    let windows = allWindowsIncludingDesktop()
    let dock = pid(ofBundle: "com.apple.dock")
    let mine = pid(ofBundle: "dev.starrydream.Dockline")
    let screens = NSScreen.screens.map { flipY($0.frame) }

    func isMenuBarLike(_ w: RawWindow) -> Bool {
        screens.contains { screen in
            w.bounds.width >= screen.width - 1 && abs(w.bounds.minY - screen.minY) <= 1
                && w.bounds.height <= menuBarMaxHeight
        }
    }

    var result: [Portrait] = []
    result += windows.filter { $0.pid == dock }
        .sorted { $0.layer > $1.layer }
        .map { portrait($0.layer == dockUILevel ? "系统程序坞 UI" : "程序坞名下其他", $0) }
    // 菜单栏那一条几何上有一大堆同尺寸的 ordered-out 僵尸 surface（本机实测二十余张）。
    // 按项目既有判别式滤掉：ordered-in 才是真窗口。数目在下面报出来，不静默丢。
    let menuBarLike = windows.filter { isMenuBarLike($0) && $0.pid != dock && $0.pid != mine }
    let liveMenuBars = menuBarLike.filter { SkyLight.isOrderedIn($0.wid) == true }
    skippedMenuBarSurfaces = menuBarLike.count - liveMenuBars.count
    result += liveMenuBars.map { portrait("疑似菜单栏", $0) }
    result += windows.filter { $0.pid == mine }
        .sorted { $0.layer > $1.layer }
        .map { portrait("Dockline", $0) }
    result += extra.compactMap { wid in
        windows.first { $0.wid == wid }.map { portrait("--wid 指定", $0) }
    }
    return result
}

// MARK: - 打印

private func spaceTypeName(_ type: Int32) -> String {
    switch type {
    case SkyLight.desktopSpaceType: return "桌面"
    case SkyLight.fullscreenSpaceTypeValue: return "全屏"
    default: return "?"
    }
}

private func spacesColumn(_ spaces: [UInt64]) -> String {
    guard !spaces.isEmpty else { return "无" }
    return spaces.map { sid in
        "\(sid)" + (SkyLight.spaceType(of: sid).map { "(\(spaceTypeName($0)))" } ?? "")
    }.joined(separator: " ")
}

private func printTopology() {
    guard let managed = SkyLight.managedDisplaySpaces() else {
        print("⚠️  CGSCopyManagedDisplaySpaces 不可用，Space 拓扑读不到：\(SkyLight.missingSymbols)")
        return
    }
    // UUID 串 → CGDirectDisplayID，好让这一段和 bar 的「每屏一条」对得上号。
    var displayByUUID: [String: CGDirectDisplayID] = [:]
    for screen in NSScreen.screens {
        guard let id = displayID(screen) else { continue }
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).takeRetainedValue()
        displayByUUID[CFUUIDCreateString(nil, uuid) as String] = id
    }

    print("── Space 拓扑 ────────────────────────────────────────────────────────")
    print("  全局 active space: \(SkyLight.activeSpace.map(String.init) ?? "—")"
          + "（多屏时它只是「最近激活的那个」，不等于每块屏的 Current Space）")
    for display in managed {
        let identifier = display["Display Identifier"] as? String ?? "?"
        let known = displayByUUID[identifier].map { "显示器 \($0)" } ?? "显示器 ?"
        let current = ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        print("  \(known)  [\(identifier)]")
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        for (index, space) in spaces.enumerated() {
            let sid = (space["id64"] as? NSNumber)?.uint64Value
            let type = (space["type"] as? NSNumber)?.int32Value
            let mark = sid == current ? "  ← 当前" : ""
            print("    #\(index + 1)  sid \(pad(sid.map(String.init) ?? "?", 6))"
                  + "type \(type.map { "\($0)（\(spaceTypeName($0))）" } ?? "?")\(mark)")
        }
    }
}

private func printPortraits(_ portraits: [Portrait]) {
    print("\n── 窗口画像 ──────────────────────────────────────────────────────────")
    print("  \(pad("wid", 9))\(pad("来源", 18))\(pad("level", 13))"
          + "\(pad("屏上", 6))\(pad("tags", 20))几何")
    print("  " + String(repeating: "─", count: 92))
    for p in portraits {
        let w = p.window
        let geometry = "\(Int(w.bounds.width))×\(Int(w.bounds.height))"
            + "@(\(Int(w.bounds.minX)),\(Int(w.bounds.minY)))"
        // CG 的 layer 与窗口服务器的 level 实测处处相同；只在不同的时候把两个都摆出来。
        let level = p.serverLevel.map { $0 == Int32(w.layer) ? "\(w.layer)" : "\(w.layer)≠srv\($0)" }
            ?? "\(w.layer)(srv 读不到)"
        print("  \(pad("\(w.wid)", 9))\(pad(p.group, 18))\(pad(level, 13))"
              + "\(pad(w.onScreen ? "是" : "否", 6))"
              + "\(pad(p.tags.map { String(format: "0x%llx", $0) } ?? "读不到", 20))\(geometry)")
        print("      位 \(pad(p.bits.map(String.init).joined(separator: " "), 34))"
              + "Space \(pad(spacesColumn(p.spaces), 36))"
              + "ordered-in \(p.orderedIn.map { $0 ? "是" : "否" } ?? "探测失败")")
    }
    if skippedMenuBarSurfaces > 0 {
        print("  （另有 \(skippedMenuBarSurfaces) 张几何像菜单栏但 ordered-out 的 surface，已按真窗口判别式滤掉）")
    }
}

/// 已经拿到实证的位。其余位一律不猜——留空比编个名字有用。
private func printLegend() {
    print("""

    ── 已认出的位（其余未定名，不猜）────────────────────────────────────
      11  all-workspaces。实证：给自建 panel 清掉这一位，它的 Space 归属立刻从
          「全部 Space」掉到「当前一个」；`.canJoinAllSpaces` 打开时它出现。
      1   与 11 互斥的那一档，`.moveToActiveSpace` 的 panel 上出现。
    """)
}

private func printDiff(_ portraits: [Portrait]) {
    print("\n── 逐位 diff：系统程序坞 UI vs Dockline ──────────────────────────────")
    let docks = portraits.filter { $0.group == "系统程序坞 UI" }
    let bars = portraits.filter { $0.group == "Dockline" }

    guard let dock = docks.first, let dockTags = dock.tags else {
        print("  ⚠️  没认出程序坞的 UI 窗口（找 pid=com.apple.dock 且 layer=\(dockUILevel) 的那张）。")
        print("     程序坞可能没在跑，或者它的 level 变了——上面的画像表里自己找一下。")
        return
    }
    if docks.count > 1 {
        print("  ⚠️  layer=\(dockUILevel) 的程序坞窗口有 \(docks.count) 张，只拿第一张做 diff。"
              + "多屏或系统改了摆法，判据要重定。")
    }
    guard !bars.isEmpty else {
        print("  ⚠️  Dockline 没在跑，diff 这一段做不了。先 `Scripts/build-app.sh` 起来再跑本命令。")
        return
    }
    print("  程序坞 wid \(dock.window.wid)  位 \(dock.bits.map(String.init).joined(separator: " "))"
          + "  Space \(spacesColumn(dock.spaces))")

    for bar in bars {
        guard let barTags = bar.tags else {
            print("  ⚠️  bar wid \(bar.window.wid) 的 tags 读不到，跳过。")
            continue
        }
        let only = { (a: UInt64, b: UInt64) in (0..<64).filter { a >> $0 & 1 == 1 && b >> $0 & 1 == 0 } }
        print("  bar wid \(bar.window.wid)"
              + "（\(Int(bar.window.bounds.width))×\(Int(bar.window.bounds.height))"
              + "，ordered-in \(bar.orderedIn.map { $0 ? "是" : "否" } ?? "?")）"
              + "  位 \(bar.bits.map(String.init).joined(separator: " "))"
              + "  Space \(spacesColumn(bar.spaces))")
        print("    程序坞有而 bar 没有: \(only(dockTags, barTags).map(String.init).joined(separator: " "))")
        print("    bar 有而程序坞没有: \(only(barTags, dockTags).map(String.init).joined(separator: " "))")
        print("    两边都有            : \((0..<64).filter { dockTags >> $0 & 1 == 1 && barTags >> $0 & 1 == 1 }.map(String.init).joined(separator: " "))")
    }
}

// MARK: - 快照

func commandSpaces(extraWIDs: [CGWindowID]) {
    if !SkyLight.available {
        print("⚠️  SkyLight 第 1 层不可用，缺失符号：\(SkyLight.missingSymbols.joined(separator: ", "))\n")
    }
    printTopology()
    let portraits = interestingWindows(extra: extraWIDs)
    if !portraits.isEmpty, portraits.allSatisfy({ $0.tags == nil }) {
        // 探不动就直说。这个命令的全部价值都在 tag 上，读不到就没有降级可言。
        print("\n⚠️  一个窗口的 tags 都读不到——SLSGetWindowTags 缺失，或位宽约定变了。")
    }
    printPortraits(portraits)
    printDiff(portraits)
    printLegend()
    print("""

    下一步（本命令给不出答案的部分）：转场里谁在动，要靠 `docklinespike spaces --watch 秒`。
    那里逐帧摆出每个 Space 的 transform 与被盯窗口的几何——程序坞的窗口在转场全程
    坐标不变，归属某个 Space 的窗口则整条跟着位移，两者一眼分得开。
    """)
}

// MARK: - watch（转场期间的连续采样）
//
// 采两样东西：每个 Space 的 transform（窗口服务器把 Space 推走的位移应当落在这里），
// 以及被盯窗口自己的 CG 几何（它的逻辑 frame 动没动）。两者分开看才说得清
// 「是窗口在动，还是整个 Space 连着窗口一起被推走」。
//
// 1327 / 1328 一并挂上，只为在时间线上标出转场的起止。**它们只覆盖一半的转场**：
// 绿灯 / Ctrl-Cmd-F 那种「窗口变成全屏」的缩放转场发（实测早于转场开始 1–19ms），
// 三指滑那种平移转场一次都不发。
//
// 滑动式转场没有任何开始事件，这一条是查过的，不是没找到：0–2047 全段订过一遍，
// 转场开始前静默，事件全落在收尾（1401 / 1329 / 1508）。逐帧事件也没有——这些号
// 平均每次转场只发两下。滑动转场的进度**只能主动读变换**，不会有人推给你。

/// 回调是 C 函数指针，捕获不了局部变量，起始时刻只能走全局。
private var watchStart = Date()


func commandSpacesWatch(seconds: Double, hz: Double, extraWIDs: [CGWindowID]) {
    let tracked = interestingWindows(extra: extraWIDs)
        .filter { $0.group != "程序坞名下其他" }   // 壁纸每屏每 Space 一张，采起来只是噪声
    guard !tracked.isEmpty else {
        FileHandle.standardError.write("spaces --watch: 一个可盯的窗口都没找到\n".data(using: .utf8)!)
        exit(1)
    }
    // Space 清单在采样开始时定死。转场中途新建 Space 会漏采——那时时间线上会看到
    // 「当前 Space 变成一个没在盯的号」，足够看出来，不必每 tick 重列。
    let spaceIDs = (SkyLight.managedDisplaySpaces() ?? []).flatMap { display in
        (display["Spaces"] as? [[String: Any]] ?? []).compactMap {
            ($0["id64"] as? NSNumber)?.uint64Value
        }
    }
    guard !spaceIDs.isEmpty else {
        FileHandle.standardError.write("spaces --watch: 读不到 Space 列表\n".data(using: .utf8)!)
        exit(1)
    }
    if SkyLight.spaceTransform(of: spaceIDs[0]) == nil {
        print("⚠️  SLSSpaceGetTransform 返回错误或符号缺失——transform 列会一路是 ✗。")
    }

    let widths = tracked.map(\.window.wid)
    print("盯住 \(tracked.count) 个窗口、\(spaceIDs.count) 个 Space，\(Int(seconds)) 秒后退出。"
          + "采样 \(Int(hz))Hz，只在读数变化时打印。")
    for t in tracked {
        print("  wid \(pad("\(t.window.wid)", 8))\(t.group)  \(Int(t.window.bounds.width))×\(Int(t.window.bounds.height))")
    }
    print("""

      要做的动作，一次一个，中间停两三秒：
        ① 三指左右滑，在两个**桌面** Space 之间来回
        ② 三指左右滑，滑到一半停住、再反向滑回去（看跟手与可取消）
        ③ 进一次原生全屏，再退出来
      要看的是两列：transform 的 tx 若全程连续变化，说明转场进度可读；窗口那一列里，
      坐标不动的是「站在 Space 体系之外」的，跟着一起变的是「归属某个 Space」的。
      （1327 / 1328 只在缩放型转场发；三指滑那种平移转场没有事件行，是正常的。）

    """)
    fflush(stdout)

    let proc: SkyLight.NotifyProc = { type, _, _, _ in
        print(String(format: "%8.3fs  ── 事件 %d（%@）", Date().timeIntervalSince(watchStart), type,
                     type == 1327 ? "转场开始" : "转场结束"))
        fflush(stdout)
    }
    watchStart = Date()
    guard SkyLight.onEvent(1327, context: nil, proc), SkyLight.onEvent(1328, context: nil, proc) else {
        FileHandle.standardError.write("SLSRegisterNotifyProc 不可用\n".data(using: .utf8)!)
        exit(1)
    }

    var previous = ""
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { _ in
        // 当前 Space 每帧都记。少了它，时间线上分不出「桌面↔桌面」和「桌面↔全屏」——
        // 静止时四个 Space 的 transform 一律是单位矩阵，光看 transform 认不出落在哪。
        // 单屏诊断用全局 active space 够了；多屏时它只是「最近激活的那个」。
        var parts = [SkyLight.activeSpace.map { sid in
            "cur=\(sid)" + (SkyLight.spaceType(of: sid).map { "(\(spaceTypeName($0)))" } ?? "")
        } ?? "cur=?"]
        for sid in spaceIDs {
            guard let (t, options) = SkyLight.spaceTransform(of: sid) else { parts.append("s\(sid)=✗"); continue }
            // 单位矩阵按 · 记，好让「谁动了」在一屏字里一眼可见。options 恒为 0 时不占地方。
            parts.append("s\(sid)="
                + (t.isIdentity ? "·" : String(format: "(%.3g,%.3g,%.3g,%.3g,%.4g,%.4g)",
                                               t.a, t.b, t.c, t.d, t.tx, t.ty))
                + (options == 0 ? "" : "/opt\(options)"))
        }
        let boxes = boundsOf(widths)
        for wid in widths {
            guard let b = boxes[wid] else { parts.append("w\(wid)=没了"); continue }
            // 坐标不动有两种可能：画着但没动，和根本没在屏上。少了 ordered-in 这一位，
            // 「程序坞转场全程钉在 (0,0)」就分不出是哪一种。✗ = 已 ordered-out。
            let hidden = SkyLight.isOrderedIn(wid) == false ? "✗" : ""
            parts.append("w\(wid)=\(hidden)@(\(Int(b.minX)),\(Int(b.minY)))")
        }
        let line = parts.joined(separator: " ")
        guard line != previous else { return }
        previous = line
        print(String(format: "%8.3fs  %@", Date().timeIntervalSince(watchStart), line))
        fflush(stdout)
    }
    timer.tolerance = 0

    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
    // 这族通知经窗口服务器连接的事件队列投递，裸 RunLoop 不泵它（见 commandEvents 的记述）。
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
}

/// 定向问这几个窗口的几何。全量列表一次 5–20ms，60Hz 下跑不动；按 wid 定向查才够快。
private func boundsOf(_ wids: [CGWindowID]) -> [CGWindowID: CGRect] {
    // 这个 API 要的是**裸窗口号**数组，不是 CFNumber 数组。`wids as CFArray` 会桥成一串
    // NSNumber，返回值恒为空——实测表现为整条时间线的窗口列全是「没了」。
    var values = wids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &values, values.count, nil),
          let raw = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
    else { return [:] }
    var result: [CGWindowID: CGRect] = [:]
    for info in raw {
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
              let dict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
        result[wid] = bounds
    }
    return result
}
