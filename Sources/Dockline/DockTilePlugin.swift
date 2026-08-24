import AppKit

/// Dock tile 插件宿主。
///
/// 这是系统 Dock 取图标的真实方式，不是 hack：App 可以在 Info.plist 里声明
/// `NSDockTilePlugIn`，指向一个 `.docktileplugin`。Dock **在 App 未运行时也会**
/// 把它加载进自己的进程，插件通过 `setDockTile:` 拿到 NSDockTile 之后自绘
/// contentView（换图标）或设 badgeLabel（角标）。
///
/// 所以这类图标不存在于任何文件里——从 bundle 读永远只能得到默认图标。
/// LaunchOS 正是如此：包里的 AppIcon.icns 是四环默认图，用户换过的九宫格图标
/// 由它自带的插件现画。要显示对，只能跟 Dock 一样做宿主。
///
/// 代价也与系统 Dock 相同：第三方代码跑在本进程里，插件崩了 Dockline 跟着崩。
/// 因此只在真的需要某个 App 的图标时才加载，不做预热。
///
/// 顺带解锁了角标：Mail 未读数一类在 App 未运行时的角标，正源就是这里的
/// badgeLabel——计划书 §3 原方案「对 Dock 进程 AX 读 AXStatusLabel」是绕远路。
final class DockTilePlugins {
    private struct Hosted {
        /// 每个 NSWindow 自带一个独立的 NSDockTile（该类没有公开构造器），借来当宿主。
        /// 窗口和插件实例都必须持有——放掉的话 contentView 随之失效。
        let window: NSWindow
        let instance: NSObject
        let tile: NSDockTile
    }

    /// 值为 nil 表示「查过了，这个 App 没有可用插件」，避免重复尝试加载
    private var hosted: [String: Hosted?] = [:]

    private func host(app url: URL, bundleID: String) -> Hosted? {
        if let known = hosted[bundleID] { return known }
        hosted[bundleID] = Hosted?.none

        guard let appBundle = Bundle(url: url),
              let name = appBundle.object(forInfoDictionaryKey: "NSDockTilePlugIn") as? String,
              let pluginURL = appBundle.builtInPlugInsURL?.appendingPathComponent(name),
              let plugin = Bundle(url: pluginURL) else { return nil }
        guard plugin.load(), let type = plugin.principalClass as? NSObject.Type else {
            NSLog("Dockline: \(bundleID) 的 dock tile 插件加载失败")
            return nil
        }
        let instance = type.init()
        let selector = NSSelectorFromString("setDockTile:")
        guard instance.responds(to: selector) else { return nil }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let tile = window.dockTile
        _ = instance.perform(selector, with: tile)

        let result = Hosted(window: window, instance: instance, tile: tile)
        hosted[bundleID] = result
        return result
    }

    /// nil = 没有插件，或插件没自绘图标（只设角标的走这条，图标仍用 bundle 的）
    func icon(app url: URL, bundleID: String) -> NSImage? {
        guard let view = host(app: url, bundleID: bundleID)?.tile.contentView else { return nil }
        let pixels = NSSize(width: 256, height: 256)
        view.frame = NSRect(origin: .zero, size: pixels)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.addRepresentation(rep)
        return image
    }

    func badge(app url: URL, bundleID: String) -> String? {
        host(app: url, bundleID: bundleID)?.tile.badgeLabel
    }
}
