import AppKit

/// 一个 App 的身份。
///
/// App 是身份与资源的单位——图标、未读角标、退出、固定、活动状态、没有窗口时的占位。
/// 它不是排布的单位：排布的单位是窗口，见 `BarElement`。
///
/// 优先用 bundle ID：它跨重启稳定，固定 App 的位置才不会因为一次退出就丢。
/// 没有 bundle ID 的进程退回 pid——那种身份只在会话内有效，也无法固定。
enum AppKey: Hashable, Codable {
    case bundle(String)
    case process(pid_t)

    var bundleID: String? {
        if case .bundle(let id) = self { return id }
        return nil
    }
}

/// 固定项与顺序的持久化。计划书 §4：App 级顺序跨重启保持。
///
/// 存成可手改的 JSON，不用 UserDefaults：出问题时能直接打开看，也能直接改。
final class PinStore {
    struct Config: Codable {
        /// 启动台入口的目标
        var launcher: String
        /// 固定 App 的 bundle ID
        var apps: [String]
        /// 固定文件夹
        var folders: [String]
        /// App 级顺序。跨重启的粗恢复用——会话内的顺序是窗口级的（见 `WindowOrder`），
        /// 而窗口级的持久化需要一个跨重启稳定的窗口身份，那是第 9 节里未解的问题。
        var order: [String]
        /// 图标尺寸。缺省（nil）跟随系统程序坞的 tilesize。
        var iconSize: Double?
        /// 接管系统程序坞前的原始偏好，用于恢复
        var dockSnapshot: DockControl.Snapshot?
        /// 是否纠正系统最大化与拼贴的结果。缺省关闭（计划书 §3）。
        var correctsTiling: Bool?
        /// 原生标签页是否始终收成一格。缺省（nil）= 只在宽度不够时才收。
        var foldsTabs: Bool?
    }

    private static let path = ("~/Library/Application Support/Dockline/pins.json" as NSString)
        .expandingTildeInPath

    private var config: Config

    private(set) var pinnedApps: [String]
    private(set) var folders: [URL]

    var launcher: URL { URL(fileURLWithPath: config.launcher) }

    var iconSize: CGFloat? { config.iconSize.map { CGFloat($0) } }

    var dockSnapshot: DockControl.Snapshot? { config.dockSnapshot }

    func setDockSnapshot(_ snapshot: DockControl.Snapshot?) {
        config.dockSnapshot = snapshot
        save()
    }

    var correctsTiling: Bool { config.correctsTiling ?? false }

    var foldsTabs: Bool { config.foldsTabs ?? false }

    func setFoldsTabs(_ enabled: Bool) {
        config.foldsTabs = enabled
        save()
    }

    func setCorrectsTiling(_ enabled: Bool) {
        config.correctsTiling = enabled
        save()
    }

    func setIconSize(_ size: CGFloat?) {
        config.iconSize = size.map(Double.init)
        save()
    }

    func setLauncher(_ url: URL) {
        config.launcher = url.path
        save()
    }

    /// 首次运行时挑一个存在的启动器，而不是写死某个第三方 App。
    private static func defaultLauncher() -> String {
        let candidates = ["/Applications/LaunchOS.app",
                          "/System/Applications/Launchpad.app",
                          "/System/Applications/Utilities",
                          "/Applications"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/Applications"
    }

    init() {
        if let data = FileManager.default.contents(atPath: Self.path) {
            // 配置是用户可以手改的文件。改坏了要当场报出来，静默退回默认值
            // 只会让人以为固定项莫名其妙丢了。
            do {
                config = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                fatalError("\(Self.path) 解析失败：\(error)")
            }
        } else {
            config = Config(launcher: Self.defaultLauncher(),
                            apps: [], folders: [], order: [], iconSize: nil,
                            dockSnapshot: nil, correctsTiling: nil, foldsTabs: nil)
        }
        pinnedApps = config.apps
        folders = config.folders.map { URL(fileURLWithPath: $0) }
    }

    private func save() {
        config.apps = pinnedApps
        config.folders = folders.map(\.path)
        let url = URL(fileURLWithPath: Self.path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: url)
        } catch {
            fatalError("写入 \(Self.path) 失败：\(error)")
        }
    }

    // MARK: 固定项

    func isPinned(_ bundleID: String) -> Bool { pinnedApps.contains(bundleID) }

    func pin(_ bundleID: String) {
        guard !pinnedApps.contains(bundleID) else { return }
        pinnedApps.append(bundleID)
        save()
    }

    func unpin(_ bundleID: String) {
        pinnedApps.removeAll { $0 == bundleID }
        save()
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        save()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        save()
    }

    // MARK: 顺序（跨重启的粗恢复）
    //
    // 会话内的顺序由 `WindowOrder` 按窗口维护。这里只存一份由它推导出的 App 顺序，
    // 下次冷启动时用来把窗口铺开成大致相同的样子。

    /// 记忆中的位次。没记过的排在最后。
    func rank(_ key: AppKey) -> Int {
        guard let bundleID = key.bundleID, let index = config.order.firstIndex(of: bundleID) else {
            return Int.max
        }
        return index
    }

    /// 合并，不是替换。此刻没在运行的 App 必须留在记忆里、位置为它们守着——
    /// 直接覆盖的话，一个 App 关掉一次就丢了自己的位次，下次启动只能追加到末尾。
    func setAppOrder(_ fresh: [String]) {
        var merged = fresh
        let present = Set(fresh)
        var anchor: String?          // 上一个仍在场的邻居
        for id in config.order {
            if present.contains(id) {
                anchor = id
                continue
            }
            guard !merged.contains(id) else { continue }
            if let anchor, let index = merged.firstIndex(of: anchor) {
                merged.insert(id, at: index + 1)
            } else {
                merged.insert(id, at: 0)
            }
            anchor = id
        }
        guard merged != config.order else { return }
        config.order = merged
        save()
    }
}
