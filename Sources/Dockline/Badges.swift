import AppKit
import ApplicationServices

/// 未读角标的来源有两条，缺一不可：
///
///  · **App 自带的 dock tile 插件**：`badgeLabel` 由插件设置，App 未运行时也有效。
///    这是「邮件未读数在 App 没开时也显示」的正源。
///  · **系统程序坞对应项的 `AXStatusLabel`**：运行中的 App 通过自己的 `NSApp.dockTile`
///    设角标，那份状态在 App 进程内，外部读不到，只能问程序坞。
///
/// 两条都只在对账 tick 上读，且只读条上确实显示着的那几个 App。
final class BadgeReader {
    private var dockPID: pid_t?
    /// bundle 路径 -> 程序坞里的对应项。程序坞不重启就一直有效。
    private var dockItems: [String: AXUIElement] = [:]

    private func copy(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            ? value : nil
    }

    /// 程序坞重启（如改过偏好后 killall）会让缓存的元素全部失效，按 pid 变化重建。
    private func refreshDockItemsIfNeeded() {
        // 认得出还是那个程序坞就到此为止。**不要每轮都去枚举全部运行中的 App**——
        // 那要向 LaunchServices 逐个问 bundle ID，而绝大多数轮次它只是把同一个 pid
        // 又认了一遍。实测那一下占掉空置开销的一成半。
        if let dockPID, !dockItems.isEmpty,
           NSRunningApplication(processIdentifier: dockPID)?.isTerminated == false { return }
        guard let dock = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return }
        dockPID = dock.processIdentifier
        dockItems = [:]

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for list in copy(app, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for item in copy(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let url = copy(item, kAXURLAttribute) as? NSURL,
                      let path = url.path else { continue }
                dockItems[path] = item
            }
        }
    }

    /// - Parameter apps: bundle ID -> App 包位置
    func badges(for apps: [String: URL], plugins: DockTilePlugins) -> [String: String] {
        refreshDockItemsIfNeeded()
        var result: [String: String] = [:]
        for (bundleID, url) in apps {
            if let label = plugins.badge(app: url, bundleID: bundleID),
               !label.isEmpty {
                result[bundleID] = label
                continue
            }
            if let item = dockItems[url.path],
               let label = copy(item, "AXStatusLabel") as? String,
               !label.isEmpty {
                result[bundleID] = label
            }
        }
        return result
    }
}
