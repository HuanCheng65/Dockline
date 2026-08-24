import AppKit
import ApplicationServices
import DocklineCore

// MARK: - probe —— 窗口画像
//
// 只读诊断：把每个 CG 候选窗口的全部判据摊开，供确立过滤谓词用。
// 不复用 buildWindowIndex 的判决逻辑，因为要看的正是「它凭什么这么判」。
//
//   docklinespike probe [--after 秒] [--min 边长]
//
// --after 用于捕捉需要手动触发、且会占住前台的场景（调度中心、菜单栏弹窗）：
// 先起命令，再去触发，到点自动采样。

private let probeAttributes = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
    kAXMinimizedAttribute, "AXFullScreen", kAXModalAttribute,
    kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute,
    kAXGrowAreaAttribute, kAXMainAttribute, kAXRoleDescriptionAttribute,
]

private struct Portrait {
    let cg: CGWindowRecord
    let policy: String
    let orderedIn: Bool?
    let spaces: [UInt64]
    let hasAX: Bool
    let role: String?
    let subrole: String?
    let axTitle: String?
    let minimized: Bool?
    let fullscreen: Bool?
    let modal: Bool?
    let close: Bool
    let minimizeButton: Bool
    let zoom: Bool
    let grow: Bool
    let main: Bool?
    let roleDescription: String?
}

func commandProbe(after delay: Double, minimumSize: CGFloat) {
    if delay > 0 {
        print("\(Int(delay)) 秒后采样——现在去触发要复现的场景，保持它在屏幕上。")
        for remaining in stride(from: Int(delay), through: 1, by: -1) {
            FileHandle.standardError.write("  \(remaining)…\n".data(using: .utf8)!)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    let candidates = enumerateCGWindows().filter {
        isCandidate($0) && $0.bounds.width >= minimumSize && $0.bounds.height >= minimumSize
    }
    let owners = Set(candidates.map(\.pid))

    // 逐 App 取窗口，并对每个窗口批量取齐画像属性
    var axByID: [CGWindowID: [AnyObject?]] = [:]
    var axWindowCount: [pid_t: Int] = [:]
    for pid in owners {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        // 枚举失败与「枚举成功但没有这个窗口」是两回事，axWindowCount 有没有值就是这个分野
        guard let windows = axCopy(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
        axWindowCount[pid] = windows.count
        for window in windows {
            guard let wid = windowID(of: window).id else { continue }
            axByID[wid] = axCopyMultiple(window, probeAttributes)
        }
    }

    let active = SkyLight.activeSpace
    let portraits = candidates.map { cg -> Portrait in
        let app = NSRunningApplication(processIdentifier: cg.pid)
        let policy: String
        switch app?.activationPolicy {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        default: policy = "—"
        }
        let got = axByID[cg.windowID]
        return Portrait(
            cg: cg,
            policy: policy,
            orderedIn: SkyLight.isOrderedIn(cg.windowID),
            spaces: SkyLight.spaces(for: cg.windowID) ?? [],
            hasAX: got != nil,
            role: got?[0] as? String,
            subrole: got?[1] as? String,
            axTitle: got?[2] as? String,
            minimized: got?[3] as? Bool,
            fullscreen: got?[4] as? Bool,
            modal: got?[5] as? Bool,
            close: got?[6] != nil,
            minimizeButton: got?[7] != nil,
            zoom: got?[8] != nil,
            grow: got?[9] != nil,
            main: got?[10] as? Bool,
            roleDescription: got?[11] as? String)
    }

    print("当前 Space: \(active.map(String.init) ?? "—") · CG 候选 \(portraits.count) 个"
          + "（layer 0 · alpha>0.05 · ≥\(Int(minimumSize))²）\n")

    // 索引会怎么判。判据本身一律调用 DocklineCore 里那几个谓词，这里只负责按顺序问一遍，
    // 不自带第二份规则——探针和 bar 的结论必须永远一致。
    func verdict(_ p: Portrait) -> String {
        let minimized = p.minimized == true
        guard p.orderedIn == true || minimized else { return "✗ ordered-out 且非最小化" }
        guard p.hasAX else {
            guard axWindowCount[p.cg.pid] != nil else { return "★ 收（CG-only，AX 枚举失败）" }
            return axSilenceIsEvidence(spaces: p.spaces)
                ? "✗ AX 树里没有它，而它不在别的 Space" : "★ 收（CG-only）"
        }
        if !isDisplayableSubrole(p.subrole) { return "✗ subrole 被排除" }
        if !p.close { return "✗ 面板：没有关闭按钮" }
        return "★ 收（AX）"
    }

    print("  \(pad("wid", 7))\(pad("App", 16))\(pad("policy", 10))\(pad("尺寸", 11))"
          + "\(pad("ord-in", 8))\(pad("Space", 8))判决")
    print("  " + String(repeating: "─", count: 96))
    for p in portraits.sorted(by: { ($0.cg.ownerName, $0.cg.windowID) < ($1.cg.ownerName, $1.cg.windowID) }) {
        let size = "\(Int(p.cg.bounds.width))×\(Int(p.cg.bounds.height))"
        let space = p.spaces.isEmpty ? "—" : p.spaces.map(String.init).joined(separator: "/")
            + (active.map { p.spaces.contains($0) } == true ? "*" : "")
        print("  " + [pad("\(p.cg.windowID)", 7), pad(p.cg.ownerName, 16), pad(p.policy, 10),
                      pad(size, 11), pad(p.orderedIn.map(String.init) ?? "探测失败", 8),
                      pad(space, 8), verdict(p)].joined())
        let title = p.axTitle?.isEmpty == false ? p.axTitle! : (p.cg.cgTitle ?? "—")
        if p.hasAX {
            let flags = [p.minimized == true ? "min" : nil, p.fullscreen == true ? "full" : nil,
                         p.modal == true ? "MODAL" : nil, p.main == true ? "main" : nil]
                .compactMap { $0 }
            print("        AX  role=\(p.role ?? "—") subrole=\(p.subrole ?? "—")"
                  + "  按钮[关闭=\(mark(p.close)) 最小化=\(mark(p.minimizeButton))"
                  + " 缩放=\(mark(p.zoom)) 可调整=\(mark(p.grow))]"
                  + (flags.isEmpty ? "" : "  \(flags.joined(separator: ","))"))
            print("        描述=\(p.roleDescription ?? "—")  标题=\(title)")
        } else {
            let count = axWindowCount[p.cg.pid].map(String.init) ?? "取不到"
            print("        AX  无记录（该进程 AXWindows 有 \(count) 个）  CG 标题=\(title)")
        }
    }
}

private func mark(_ value: Bool) -> String { value ? "有" : "无" }
