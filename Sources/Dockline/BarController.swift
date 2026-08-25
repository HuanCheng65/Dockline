import AppKit
import DocklineCore

/// 每块显示器一条 bar（计划书 §6 M5）。这里负责它们的生灭：接上一块屏就多一条，
/// 拔掉一块就少一条，分辨率变了就重摆。
///
/// 显示器的键取 `CGDirectDisplayID`。它在拔插后会被重新分配，因此**不能用来判断
/// 「是不是同一块屏又回来了」**——Display Memory 那件事要用 UUID（见计划书 §6 的 spike）。
/// 但在同一时刻区分现存的几块屏，它是准的，而这里要的只是这一点。
final class BarController {
    private let world: World
    private var panels: [CGDirectDisplayID: BarPanel] = [:]

    /// 全部 bar 共用一个自建的 private Space，第一条 bar 上线时建出来。
    ///
    /// 没有销毁路径，`SLSSpaceDestroy` 也就没有封装。退出时销毁挡不住任何东西——
    /// 崩溃与被 kill 时那条路根本不跑。所以只有两种可能：窗口服务器随连接断开自己回收，
    /// 那就不必调；或者它不回收，那要解决的也不是「正常退出」这一种情形。
    private var privateSpace: UInt32?

    init(world: World) {
        self.world = world
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.sync() }
    }

    func start() {
        sync()
    }

    /// 与现实对齐。屏幕重新配置的过程中 `NSScreen.screens` 会短暂地不完整，
    /// 空列表按「还没配置好」处理：拆掉全部 bar 再建回来，会把每条 bar 的溢出迟滞、
    /// 明暗、隐藏状态全部丢掉，而这类抖动几百毫秒后就自己好了。
    private func sync() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            Timeline.log("⚠️ 屏幕参数变化时一块屏都没列出来，本轮不动 bar")
            return
        }

        var live = Set<CGDirectDisplayID>()
        for screen in screens {
            guard let id = displayID(screen) else {
                Timeline.log("⚠️ 有一块屏读不到显示器编号，它上面不会有 bar")
                continue
            }
            live.insert(id)
            if let panel = panels[id] {
                panel.update(screen: screen)
                continue
            }
            let panel = BarPanel(world: world, screen: screen)
            panels[id] = panel
            panel.orderFrontRegardless()
            Timeline.log("屏 \(id) 上线，建一条 bar")
            pin(panel)
        }

        for (id, panel) in panels where !live.contains(id) {
            world.unregister(panel.model)
            panel.orderOut(nil)
            panels[id] = nil
            Timeline.log("屏 \(id) 离线，撤掉它的 bar")
        }

        // 屏数变了，指针监听的需要也可能变了
        world.updateMouseMonitor()
    }

    /// 把这条 bar 挂进自建的 private Space，让它在桌面之间切换时钉住不动（计划书 §4）。
    ///
    /// 挂载后归属不需要维护——实测它扛得住 orderOut→orderFront 与长时间静置，
    /// 所以 `update(screen:)` 那条路不必重挂。
    private func pin(_ panel: BarPanel) {
        let wid = CGWindowID(panel.windowNumber)
        guard PrivateSpace.available else {
            unpinned(panel, "私有 Space 符号缺失：\(PrivateSpace.missingSymbols)")
            return
        }
        // 只是留给失败信息用。刚上屏的窗口有一段时间 ordered-in 已经为真、受管 Space
        // 归属却还是空的，长短不定——所以这里不拿它当门槛，成没成一律以回读为准。
        let before = SkyLight.spaces(for: wid)
        let space: UInt32
        if let existing = privateSpace {
            space = existing
        } else {
            guard let created = PrivateSpace.create() else {
                unpinned(panel, "建不出 private Space")
                return
            }
            privateSpace = created
            space = created
            Timeline.log("建出 private Space \(created)，bar 挂在它上面")
        }
        guard PrivateSpace.attach([wid], to: space) else {
            unpinned(panel, "窗口 \(wid) 挂进 private Space \(space) 被拒")
            return
        }
        // 写完立刻回读，且要正面读到我们那个 space——0x7 掩码看不见私有 Space，
        // 得用把第 3 位算上的 0xF（见 `SkyLight.spaces(for:mask:)`）。
        let after = SkyLight.spaces(for: wid, mask: SkyLight.allSpacesIncludingPrivateMask)
        guard after == [UInt64(space)] else {
            let read = after?.description ?? "读不到"
            let was = before?.description ?? "读不到"
            let ordered = SkyLight.isOrderedIn(wid)?.description ?? "读不到"
            unpinned(panel, "窗口 \(wid) 挂进 private Space \(space) 后回读是 \(read)，"
                            + "这次写没生效（挂载前 \(was)，ordered-in=\(ordered)）")
            return
        }
    }

    /// 挂载没成。条退回 `.canJoinAllSpaces`：会跟着桌面滑走，但每个 Space 上都还有。
    private func unpinned(_ panel: BarPanel, _ reason: String) {
        panel.fallBackToAllSpaces()
        Timeline.log("⚠️ bar 钉不住，退回跟随桌面：\(reason)")
    }
}
