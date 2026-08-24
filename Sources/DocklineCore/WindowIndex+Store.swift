import AppKit
import ApplicationServices

/// bar / 搜索层 / 时光机的唯一数据源。计划书 §4「窗口索引」。
/// 一次索引构建的分段耗时，用于盯住计划书 §2 的 tick 预算。
public struct IndexTiming {
    public var cgList: Double = 0        // CGWindowList + 过滤
    public var orderedIn: Double = 0     // 逐窗口 SLSWindowIsOrderedIn
    public var axProbe: Double = 0       // 受限 pid 的 AX 枚举（含批量属性读取）
    public init() {}
    public init(cgList: Double, orderedIn: Double, axProbe: Double) {
        self.cgList = cgList; self.orderedIn = orderedIn; self.axProbe = axProbe
    }
    public var total: Double { cgList + orderedIn + axProbe }
}

/// bar 只收「用户会想找回来的窗口」。
///
/// 这里用排除法而不是白名单，是被实机纠正过的：微信主窗口的 subrole 是 `AXDialog`，
/// 白名单只认 `AXStandardWindow` 时，它在别的 Space（无 AX 记录、跳过检查）能正常显示，
/// 一旦被最小化、拿到 AX 记录反而被踢出去。窗口不该因为我们对它了解变多而消失。
public let excludedSubroles: Set<String> = [
    "AXUnknown",              // 通知中心 widget、各类隐形窗口
    "AXSystemDialog",         // 系统级浮层
    "AXSheet",                // 附着在父窗口上的 sheet，不该单独占一格
    "AXPopover",
    "AXSystemFloatingWindow",
]

/// - Parameter subrole: nil / 空表示 AX 有记录但读不到 subrole（访达桌面窗口即如此），一律排除。
public func isDisplayableSubrole(_ subrole: String?) -> Bool {
    guard let subrole, !subrole.isEmpty else { return false }
    return !excludedSubroles.contains(subrole)
}

/// bundle ID 只跟进程有关，与 AX 通道无关。此前它只在 AX 路径上填，
/// 结果跨 Space 的 CG-only 窗口一律没有 bundle ID——而 bar 的固定槽位正是按
/// bundle ID 认身份的，访达那样常年待在别的 Space 的 App 就永远固定不了。
public func bundleID(of pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

/// 某个 CG 候选窗口未能进入索引的原因。诊断用——只在 CLI 的 index 命令里展开。
public struct IndexRejection {
    public let id: CGWindowID
    public let app: String
    public let size: CGSize
    public let orderedIn: Bool?
    public let subrole: String?
    public let hasAX: Bool
    public let reason: String
}

public struct IndexedWindow: Identifiable, Equatable {
    public enum Source: Equatable {
        case ax          // 当前 Space 或最小化——有 AX 引用，可直接召回
        case cgOnly      // 其他 Space 的存量窗口——无 AX 引用，走激活 App 粗路认领
        case tab(host: CGWindowID)   // 原生标签页的后台标签——按标签栏上的那一项召回
    }

    public let id: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let bundleID: String?
    public let title: String
    public let element: AXUIElement?
    public let minimized: Bool
    public let fullscreen: Bool
    public let spaces: [UInt64]
    public let source: Source

    public static func == (a: IndexedWindow, b: IndexedWindow) -> Bool {
        a.id == b.id && a.title == b.title && a.minimized == b.minimized
            && a.fullscreen == b.fullscreen && a.source == b.source
    }
}

/// 原生标签页的后台标签。
///
/// 采用系统原生标签页的 App（访达、Ghostty 等），非当前标签在窗口服务器里仍是一个
/// layer 0 的 surface、带着自己的标题，但既不 ordered-in，也不出现在 App 的 AXWindows 里
/// ——当前标签才是那唯一的 AX 窗口。它因此被真窗口判别式挡在门外。
///
/// 判据：与同进程某个在场窗口的几何完全相同，且有非空标题。返回宿主窗口的 wid。
/// 本机实测（2026-08）：52 个非 ordered-in 的 layer 0 候选中只有 3 个命中，全部是真标签页；
/// 僵尸 surface 停在各自过时的位置上，不会与在场窗口重合。
public func tabHost(of candidate: CGWindowRecord, among live: [CGWindowRecord]) -> CGWindowID? {
    guard let title = candidate.cgTitle, !title.isEmpty else { return nil }
    return live.first { $0.pid == candidate.pid && $0.bounds == candidate.bounds }?.windowID
}

/// 几何重合还不够。有一类僵尸 surface 会漏过去：最大化过的窗口关掉后留下的 surface，
/// 与同 App 另一个最大化窗口的矩形完全相同（实测样本里就有几个）。
/// 标签栏上有没有同名的一项，是能把二者分开的判据。只对通过几何判据的候选做，每轮至多几次。
public func isTabOfHost(_ candidate: CGWindowRecord, host: CGWindowID) -> Bool {
    guard let title = candidate.cgTitle,
          let hostElement = axWindow(pid: candidate.pid, wid: host),
          let group = tabGroup(in: hostElement) else { return false }
    return ((axCopy(group, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        .contains { axCopy($0, kAXTitleAttribute) as? String == title }
}

func tabWindow(candidate: CGWindowRecord, host: CGWindowID,
               previous: IndexedWindow? = nil) -> IndexedWindow {
    IndexedWindow(
        id: candidate.windowID,
        pid: candidate.pid,
        appName: previous?.appName ?? candidate.ownerName,
        bundleID: bundleID(of: candidate.pid),
        title: candidate.cgTitle ?? previous?.title ?? candidate.ownerName,
        element: nil,
        minimized: false,
        fullscreen: false,
        spaces: SkyLight.spaces(for: candidate.windowID) ?? previous?.spaces ?? [],
        source: .tab(host: host))
}

/// 合并 AX 通道与 CG 对账通道，产出当前应当出现在 bar 上的窗口集合。
///
/// 过滤规则（计划书 §4，由 M0/M0.5 实测确立）：
///  · CG 侧：layer 0、非全透明、尺寸达标、排除自身进程
///  · 真窗口判别：`ordered-in == true` **或** AX 报告 `AXMinimized == true`
///    （最小化窗口是 ordered-out，且在 CG 层面与「关掉但没销毁」的僵尸 surface 无法区分）
///  · 有 AX 记录的窗口以 AX 的 subrole 为准，只收 `AXStandardWindow`；
///    无 AX 记录的（其他 Space）只能靠 CG 判据，这是已知的精度损失
public func buildWindowIndex(minimumSize: CGFloat = 120) -> [IndexedWindow] {
    var timing = IndexTiming()
    return buildWindowIndex(minimumSize: minimumSize, timing: &timing)
}

public func buildWindowIndex(minimumSize: CGFloat = 120, timing: inout IndexTiming) -> [IndexedWindow] {
    var rejections: [IndexRejection] = []
    return buildWindowIndex(minimumSize: minimumSize, timing: &timing, rejections: &rejections)
}

public func buildWindowIndex(minimumSize: CGFloat = 120, timing: inout IndexTiming,
                             rejections: inout [IndexRejection]) -> [IndexedWindow] {
    // 先跑廉价的 CG 通道，由它圈定「确实拥有候选窗口」的进程；
    // AX 只探这几个 pid。计划书 §2：不遍历全部运行中 App。
    let t0 = Date()
    let candidates = enumerateCGWindows().filter {
        isCandidate($0) && $0.bounds.width >= minimumSize && $0.bounds.height >= minimumSize
    }
    let owners = Set(candidates.map(\.pid))
    let t1 = Date()

    var axByID: [CGWindowID: WindowRecord] = [:]
    for record in enumerateAXWindows(pids: owners).windows {
        guard let id = record.windowID else { continue }
        axByID[id] = record
    }
    let t2 = Date()
    timing.cgList = t1.timeIntervalSince(t0) * 1000
    timing.axProbe = t2.timeIntervalSince(t1) * 1000
    let orderedStart = Date()

    let live = candidates.filter { SkyLight.isOrderedIn($0.windowID) == true }

    var result: [IndexedWindow] = []
    for cg in candidates {
        let ax = axByID[cg.windowID]
        let minimized = ax?.minimized == true
        let orderedIn = SkyLight.isOrderedIn(cg.windowID)

        func reject(_ reason: String) {
            rejections.append(IndexRejection(id: cg.windowID, app: ax?.appName ?? cg.ownerName,
                                             size: cg.bounds.size, orderedIn: orderedIn,
                                             subrole: ax?.subrole, hasAX: ax != nil, reason: reason))
        }
        guard orderedIn == true || minimized else {
            if let host = tabHost(of: cg, among: live), isTabOfHost(cg, host: host) {
                result.append(tabWindow(candidate: cg, host: host))
            } else {
                reject(orderedIn == nil ? "ordered-in 探测失败" : "ordered-out 且非最小化")
            }
            continue
        }
        if let ax, !isDisplayableSubrole(ax.subrole) {
            reject("subrole 在排除名单里：\(ax.subrole ?? "nil")")
            continue
        }
        if let ax, !isRealWindow(ax) {
            reject("菜单栏 App 的面板：没有关闭按钮")
            continue
        }

        let axTitle = ax?.title.flatMap { $0.isEmpty ? nil : $0 }
        let cgTitle = cg.cgTitle.flatMap { $0.isEmpty ? nil : $0 }
        result.append(IndexedWindow(
            id: cg.windowID,
            pid: cg.pid,
            appName: ax?.appName ?? cg.ownerName,
            bundleID: bundleID(of: cg.pid),
            title: axTitle ?? cgTitle ?? (ax?.appName ?? cg.ownerName),
            element: ax?.element,
            minimized: minimized,
            fullscreen: ax?.fullscreen == true,
            spaces: ax?.spaces ?? SkyLight.spaces(for: cg.windowID) ?? [],
            source: ax == nil ? .cgOnly : .ax))
    }
    timing.orderedIn = Date().timeIntervalSince(orderedStart) * 1000
    return result
}

/// 维护 bar 上的稳定顺序，并承载增量更新。
/// 计划书 §2「顺序稳定性高于新近度」：存活窗口绝不自动重排，新窗口只追加于尾部。
public final class WindowIndexStore {
    private var order: [CGWindowID] = []
    private var byID: [CGWindowID: IndexedWindow] = [:]
    private var established = false
    private let minimumSize: CGFloat
    /// 已经做过判定的 wid——含被 subrole/尺寸否掉的，避免对它们无休止地重复探测
    private var evaluated = Set<CGWindowID>()
    /// 上一 tick 的 ordered-in 状态。探测的触发条件是「状态跃迁」，不是「状态本身」：
    /// 最小化窗口稳定处于 ordered-out，那是它的常态而非变化。
    private var lastOrderedIn: [CGWindowID: Bool] = [:]
    /// 几何判据过了、标签栏核对没过的 surface。核对是跨进程调用，
    /// 不记住否决结果的话，这类候选每轮对账都要重查一次（自绘标签栏的 App 永远查不过）。
    private var rejectedTabs = Set<CGWindowID>()

    public private(set) var timing = IndexTiming()
    /// 上一次 refreshApp 中被跳过的窗口及原因——诊断「新窗口为何没有立刻出现」
    public private(set) var lastSkipped: [String] = []
    public var windows: [IndexedWindow] { order.compactMap { byID[$0] } }

    public init(minimumSize: CGFloat = 120) { self.minimumSize = minimumSize }

    // MARK: 通道三 —— CG 对账
    //
    // 稳态下只对两类进程做 AX 探测：
    //  · 出现了我们没见过的 ordered-in 窗口（需要认领）
    //  · 我们已知的窗口转为 ordered-out（需要区分「被最小化」和「被关掉」——
    //    这两者在 CG 层面完全一样，只有 AX 分得开）
    // 其余情况一次 AX 调用都不做。

    @discardableResult
    public func reconcile() -> Bool {
        let t0 = Date()
        let candidates = enumerateCGWindows().filter {
            isCandidate($0) && $0.bounds.width >= minimumSize && $0.bounds.height >= minimumSize
        }
        let t1 = Date()

        var orderedIn: [CGWindowID: Bool] = [:]
        for candidate in candidates {
            orderedIn[candidate.windowID] = SkyLight.isOrderedIn(candidate.windowID) == true
        }
        let t2 = Date()

        var probePIDs = Set<pid_t>()
        if established {
            for candidate in candidates {
                let id = candidate.windowID
                let live = orderedIn[id] == true
                let isNew = !evaluated.contains(id)
                let flipped = lastOrderedIn[id] != nil && lastOrderedIn[id] != live
                if isNew || flipped { probePIDs.insert(candidate.pid) }
            }
        } else {
            probePIDs = Set(candidates.map(\.pid))
        }

        var axByID: [CGWindowID: WindowRecord] = [:]
        if !probePIDs.isEmpty {
            for record in enumerateAXWindows(pids: probePIDs).windows {
                guard let id = record.windowID else { continue }
                axByID[id] = record
            }
        }
        let t3 = Date()
        timing = IndexTiming(cgList: t1.timeIntervalSince(t0) * 1000,
                             orderedIn: t2.timeIntervalSince(t1) * 1000,
                             axProbe: t3.timeIntervalSince(t2) * 1000)

        // 本轮探测过的进程，其名下所有候选窗口都已做出判定，不必再探第二次
        for candidate in candidates where probePIDs.contains(candidate.pid) {
            evaluated.insert(candidate.windowID)
        }
        lastOrderedIn = orderedIn
        // 消失的窗口从记忆里清掉，否则 wid 复用时会误判为「已判定」
        let alive = Set(candidates.map(\.windowID))
        evaluated.formIntersection(alive)
        rejectedTabs.formIntersection(alive)

        let liveWindows = candidates.filter { orderedIn[$0.windowID] == true }

        var fresh: [CGWindowID: IndexedWindow] = [:]
        for candidate in candidates {
            let ax = axByID[candidate.windowID]
            let previous = byID[candidate.windowID]
            let live = orderedIn[candidate.windowID] == true

            // 最小化判定优先级：本轮新鲜的 AX > 「ordered-in 即未最小化」> 上一轮的值。
            // 中间那条依据 M0.5 实测：最小化窗口一律是 ordered-out。
            let minimized = ax?.minimized ?? (live ? false : (previous?.minimized ?? false))
            guard live || minimized else {
                // 标签栏核对只在候选第一次出现时做：已经认下的沿用（存在性由 CG 列表负责），
                // 已经否决的记住（见 rejectedTabs）。
                guard let host = tabHost(of: candidate, among: liveWindows),
                      !rejectedTabs.contains(candidate.windowID) else { continue }
                if previous == nil, !isTabOfHost(candidate, host: host) {
                    rejectedTabs.insert(candidate.windowID)
                    continue
                }
                fresh[candidate.windowID] = tabWindow(candidate: candidate, host: host,
                                                      previous: previous)
                continue
            }
            if let ax, !isDisplayableSubrole(ax.subrole) { continue }
            if let ax, !isRealWindow(ax) { continue }
            if ax == nil, previous == nil, !live { continue }

            fresh[candidate.windowID] = merge(candidate: candidate, ax: ax,
                                              previous: previous, minimized: minimized)
        }

        return commit(fresh: fresh, coldStart: !established)
    }

    // MARK: 通道二 —— AX 事件驱动的定向刷新
    //
    // 只探一个进程（约 2–3ms），不碰 CG 列表。标题变更、最小化这类高频事件走这里，
    // 不必等对账 tick，也不必为它付全量 CG 的代价。

    @discardableResult
    public func refreshApp(pid: pid_t) -> Bool {
        guard established else { return reconcile() }
        var changed = false
        lastSkipped = []

        for record in enumerateAXWindows(pids: [pid]).windows {
            guard let id = record.windowID else {
                lastSkipped.append("\(record.appName) 取不到 wid（\(record.title ?? "无标题")）")
                continue
            }
            guard isDisplayableSubrole(record.subrole) else {
                lastSkipped.append("wid \(id) subrole=\(record.subrole ?? "nil") 被排除")
                continue
            }
            guard isRealWindow(record) else {
                lastSkipped.append("wid \(id) 是菜单栏 App 的面板（没有关闭按钮）")
                continue
            }
            guard let frame = record.frame else {
                lastSkipped.append("wid \(id) 读不到几何")
                continue
            }
            guard frame.width >= minimumSize, frame.height >= minimumSize else {
                lastSkipped.append("wid \(id) 尺寸 \(Int(frame.width))×\(Int(frame.height)) 小于 \(Int(minimumSize))")
                continue
            }

            let updated = IndexedWindow(
                id: id, pid: pid,
                appName: record.appName,
                bundleID: record.bundleID,
                title: record.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? byID[id]?.title ?? record.appName,
                element: record.element,
                minimized: record.minimized == true,
                fullscreen: record.fullscreen == true,
                spaces: record.spaces ?? byID[id]?.spaces ?? [],
                source: .ax)
            if byID[id] != updated {
                byID[id] = updated
                changed = true
            }
            if !order.contains(id) { order.append(id); changed = true }
        }

        // 该进程下我们记着、但 AX 已经不认的窗口：可能真被关了，也可能只是跑去了别的 Space。
        // 这里不擅自删除——存在性由通道三的 CG 对账负责，那才是唯一有权删除的地方。
        return changed
    }

    /// kAXUIElementDestroyed 是确定性信号——元素真的没了，不同于「AX 列表里看不到」
    /// （后者可能只是窗口跑去了别的 Space）。因此这里可以立即删除，不必等对账。
    /// 已销毁的元素查不出 wid，只能按 CFEqual 反查。
    @discardableResult
    public func removeWindow(matching element: AXUIElement) -> Bool {
        guard let id = order.first(where: {
            guard let known = byID[$0]?.element else { return false }
            return CFEqual(known, element)
        }) else { return false }
        order.removeAll { $0 == id }
        byID[id] = nil
        evaluated.remove(id)
        lastOrderedIn[id] = nil
        return true
    }

    public func removeApp(pid: pid_t) {
        let gone = order.filter { byID[$0]?.pid == pid }
        guard !gone.isEmpty else { return }
        order.removeAll { gone.contains($0) }
        for id in gone { byID[id] = nil }
    }

    // MARK: 内部

    private func merge(candidate: CGWindowRecord, ax: WindowRecord?,
                       previous: IndexedWindow?, minimized: Bool) -> IndexedWindow {
        let axTitle = ax?.title.flatMap { $0.isEmpty ? nil : $0 }
        let cgTitle = candidate.cgTitle.flatMap { $0.isEmpty ? nil : $0 }
        // AX 引用一旦拿到就长期有效（M0 验证跨 Space 仍可用），沿用旧的不要丢
        let element = ax?.element ?? previous?.element
        return IndexedWindow(
            id: candidate.windowID,
            pid: candidate.pid,
            appName: ax?.appName ?? previous?.appName ?? candidate.ownerName,
            bundleID: bundleID(of: candidate.pid),
            title: axTitle ?? cgTitle ?? previous?.title ?? candidate.ownerName,
            element: element,
            minimized: minimized,
            fullscreen: ax?.fullscreen ?? previous?.fullscreen ?? false,
            spaces: ax?.spaces ?? SkyLight.spaces(for: candidate.windowID) ?? previous?.spaces ?? [],
            source: element == nil ? .cgOnly : .ax)
    }

    private func commit(fresh: [CGWindowID: IndexedWindow], coldStart: Bool) -> Bool {
        let newOrder: [CGWindowID]
        if coldStart {
            // 冷启动：同 App 窗口聚拢相邻（计划书 §3「纯视觉聚拢，可自由拖散」）
            newOrder = fresh.values
                .sorted { $0.appName == $1.appName ? $0.id < $1.id : $0.appName < $1.appName }
                .map(\.id)
            established = true
        } else {
            var kept = order.filter { fresh[$0] != nil }
            let existing = Set(kept)
            kept.append(contentsOf: fresh.keys.filter { !existing.contains($0) }.sorted())
            newOrder = kept
        }

        let changed = newOrder != order || fresh.keys.contains { fresh[$0] != byID[$0] }
        order = newOrder
        byID = fresh
        return changed
    }
}
