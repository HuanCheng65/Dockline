import AppKit
import DocklineCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let world = World()
    private lazy var bars = BarController(world: world)
    private lazy var keyboard = KeyboardSwitch(world: world)
    private var reconcileTimer: Timer?

    /// 计划书 §4 通道三：CGWindowList 对账兜底，1–2 秒周期。
    /// M0.5 实测单次 12.3ms，符合 §2 的 ≤15ms 预算。
    private static let reconcileInterval: TimeInterval = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须在建面板之前：`Timeline.start()` 会清空日志文件，而面板一构造
        // SwiftUI 就开始渲染、埋点随即写入。放在 BarModel.start() 里的话，
        // 面板构造期间的每一行都会被这次清空静默吃掉。
        Timeline.start()

        // 两项权限都在这里请求，使 TCC 记录归属到 Dockline.app 自身。
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOptions)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        // SkyLight 只读族是对账通道与全屏判定的前提，缺了要立刻知道，不能等到行为变怪
        if !SkyLight.available {
            FileHandle.standardError.write(
                "⚠️ SkyLight 符号缺失，窗口判别与全屏隐藏将不可用：\(SkyLight.missingSymbols)\n"
                    .data(using: .utf8)!)
        }

        // 跨 Space 迁移是私有的类加私有的方法，随时可能在某个点版本消失（计划书 §2 / §5
        // 第 1.5 层）。缺了它，拖格子分屏对别的 Space 上的窗口会安静地退回「不上膛」——
        // 那正是最容易被当成「这功能坏了」的一种表现，所以在这里先说一句。
        if !SpaceMove.available {
            Timeline.log("⚠️ 跨 Space 迁移不可用，别的 Space 上的窗口不参与分屏与「拿到本屏」："
                         + SpaceMove.missing.joined(separator: ", "))
        }

        bars.start()
        world.start()
        keyboard.start()
        tick()

        reconcileTimer = Timer.scheduledTimer(withTimeInterval: Self.reconcileInterval,
                                              repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Dockline 没有 Dock 图标也没有菜单栏图标，从访达里再点一次本体是最自然的
    /// 「打开设置」入口——否则用户只能靠在条上右键找到它。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        Timeline.log("收到 reopen 事件，打开设置")
        world.showSettings()
        return true
    }

    private func tick() {
        world.note(accessibility: AXIsProcessTrusted(),
                   screenRecording: CGPreflightScreenCaptureAccess())
        // 无辅助功能权限时 AX 枚举全线失败，跑对账只是白烧 CPU
        if world.accessibility { world.reconcile() }
        // 废纸篓状态没有通知可订阅，跟着对账 tick 顺带读一次（一次 CFPreferences 读，可忽略）
        world.refreshTrash()
        world.refreshBadges()
    }
}
