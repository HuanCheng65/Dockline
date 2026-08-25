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
}
