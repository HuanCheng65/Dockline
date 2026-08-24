import AppKit
import ApplicationServices

/// 借系统程序坞取 App 自己生成的程序坞菜单。
///
/// `applicationDockMenu(_:)` 由 App 在被程序坞询问时现场生成，没有任何公开途径索取。这里
/// 让程序坞代劳：对它的 dock item 执行 `AXShowMenu`，程序坞去问 App，我们再把条目读走；
/// 用户选中之后重新弹一次、按下对应的项。整个过程程序坞是执行代理，App 看到的是完全
/// 正常的协议交互。
///
/// 实测：20ms 拿到菜单元素，45ms 条目填满，`AXPress` 照常生效。条目是**延后填的**——
/// 一拿到菜单就读会得到空列表。
///
/// 代价是那份菜单会在程序坞藏身处闪现约 50ms，抑制不掉：我们发现它的时候它已经画出来了。
/// 所以只在真要用的时候取——右键弹菜单时一次，选中动态项时再一次。
enum DockMenu {
    struct Item {
        let title: String
        let enabled: Bool
        let checked: Bool
        /// 从根菜单到这一项的标题路径。按下时要重新弹一次菜单，靠它把项找回来。
        let path: [String]
        let children: [Item]
    }

    /// 等菜单元素出现 / 等条目填满的上限。实测各 20ms 与 45ms，这里留一个数量级的余量。
    /// 不能再宽：两轮等待加消息超时是叠加的，App 卡住时用户要等这么多倍才见到菜单，
    /// 而右键的响应延迟是最敏感的。等不到就没有动态项，菜单其余部分照常成立。
    private static let timeout = 0.4
    private static let step = 0.02

    // MARK: 系统项的标题

    /// 程序坞菜单里系统自己那些项的标题。
    ///
    /// 菜单里系统项与 App 项混在一起，而 AX 属性上完全一样——`AXIdentifier` 一律是
    /// "action:"，没有 subrole，整份菜单还都归 DockHelper 这一个进程。所以只能按标题认。
    ///
    /// 标题不硬编码，取自程序坞自己的资源：`DockMenus.plist` 用语言无关的键声明了各种
    /// 模板（SHOW_ALL_WINDOWS、HIDE、QUIT…），同 bundle 的 `DockMenus.strings` 把键翻成
    /// 当前语言。于是这个集合跟着系统语言走，换一种语言也不用改代码。
    private static let dockBundle = Bundle(path: "/System/Library/CoreServices/Dock.app")

    /// `dockBundle.localizedString` 会按 Dockline 自己声明支持的语言选资源。Dockline 目前
    /// 没有本地化 bundle，于是即使系统与程序坞是中文，它也会退回 Dock 的英文资源；
    /// AX 树里却是中文标题，过滤自然一个都对不上。这里按系统首选语言显式选 Dock 的
    /// lproj，必须与独立运行的 Dock 进程保持一致。
    private static let dockLanguageBundle: Bundle? = {
        guard let dockBundle else { return nil }
        let localization = Bundle.preferredLocalizations(
            from: dockBundle.localizations,
            forPreferences: Locale.preferredLanguages
        ).first
        guard let localization,
              let path = dockBundle.path(forResource: localization, ofType: "lproj") else {
            return dockBundle
        }
        return Bundle(path: path) ?? dockBundle
    }()

    private static func localized(_ key: String) -> String? {
        guard let title = dockLanguageBundle?.localizedString(
                forKey: key, value: nil, table: "DockMenus"),
              title != key else { return nil }
        return title
    }

    /// 与运行中的 App 有关的那几套模板。不取全部模板——「打开」「名称」这类通用词
    /// 出现在文件夹模板里，一并纳入会误伤 App 自己的同名项。
    private static let templates = ["process", "fileapp", "finder-running", "finder-quit"]

    private static let systemTitles: Set<String> = {
        guard let plist = dockBundle?.url(forResource: "DockMenus", withExtension: "plist"),
              let data = try? Data(contentsOf: plist),
              let menus = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: [[String: Any]]]
        else {
            Timeline.log("⚠️ 读不到程序坞的 DockMenus.plist，动态菜单无法区分系统项，已关闭")
            return []
        }
        var keys = Set<String>()
        func collect(_ entries: [[String: Any]]) {
            for entry in entries {
                if let name = entry["name"] as? String { keys.insert(name) }
                if let sub = entry["sub"] as? [[String: Any]] { collect(sub) }
            }
        }
        for template in templates { collect(menus[template] ?? []) }
        return Set(keys.compactMap(localized))
    }()

    /// 系统项里我们自己做不到、只能借这条路的那几个。
    enum Borrowed: String {
        /// 第三方 App 的登录项：SMAppService 只管自己的 bundle，LSSharedFileList 的写入
        /// 在 macOS 26 上已经崩了（实测段错误）。只剩程序坞代按这一条路。
        case openAtLogin = "OPEN_AT_LOGIN"
        case forceQuit = "FORCE_QUIT"

        var title: String? { DockMenu.localized(rawValue) }
    }

    /// 「选项」子菜单的标题。借用项藏在它下面，要下潜一层。
    private static var optionsTitle: String? { localized("OPTIONS") }

    static var available: Bool { !systemTitles.isEmpty }

    // MARK: 取

    struct Result {
        /// App 自己生成的那一段
        var own: [Item] = []
        /// 借用项，按键索引
        var borrowed: [Borrowed: Item] = [:]
    }

    /// - Parameter windowTitles: 该 App 此刻的窗口标题。菜单头部那段窗口列表是程序坞加的，
    ///   与我们的条重复，按标题剔掉——这份数据索引里本来就有。
    static func fetch(app path: String, windowTitles: Set<String>) -> Result {
        guard available, let item = dockItem(path: path) else { return Result() }
        guard let menu = show(item) else { return Result() }
        defer { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }

        var result = Result()
        for entry in entries(of: menu) {
            guard let title = copy(entry, kAXTitleAttribute) as? String, !title.isEmpty else {
                continue        // 分隔线：分段由我们自己重排，原样带过来没有意义
            }
            if title == optionsTitle {
                for option in entries(of: entry).compactMap({ read($0, path: [title]) }) {
                    if let key = Borrowed.allTitles[option.title] { result.borrowed[key] = option }
                }
                continue
            }
            if let key = Borrowed.allTitles[title], let read = read(entry, path: []) {
                result.borrowed[key] = read
                continue
            }
            guard !systemTitles.contains(title), !windowTitles.contains(title) else { continue }
            if let own = read(entry, path: []) { result.own.append(own) }
        }
        return result
    }

    /// 按下某一项。菜单一关，它的 AX 元素就失效了，所以重新弹一次、按标题路径找回去。
    static func press(app path: String, at titles: [String]) {
        guard let item = dockItem(path: path), let menu = show(item) else {
            Timeline.log("⚠️ 程序坞菜单按下失败：\(titles.joined(separator: " › "))，菜单弹不出来")
            return
        }
        var current = menu
        for (index, title) in titles.enumerated() {
            guard let match = entries(of: current)
                .first(where: { copy($0, kAXTitleAttribute) as? String == title }) else {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                Timeline.log("⚠️ 程序坞菜单按下失败：找不到「\(title)」，菜单已变")
                return
            }
            if index == titles.count - 1 {
                let status = AXUIElementPerformAction(match, kAXPressAction as CFString)
                if status != .success {
                    Timeline.log("⚠️ 程序坞菜单按下「\(title)」失败 AXError \(status.rawValue)")
                }
                return
            }
            guard let sub = submenu(of: match) else {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                Timeline.log("⚠️ 程序坞菜单按下失败：「\(title)」没有子菜单")
                return
            }
            current = sub
        }
    }

    // MARK: AX

    private static func dockItem(path: String) -> AXUIElement? {
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard let dock = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        for list in copy(app, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for item in copy(list, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let url = copy(item, kAXURLAttribute) as? NSURL else { continue }
                let found = (url as URL).resolvingSymlinksInPath().standardizedFileURL.path
                if found == wanted { return item }
            }
        }
        return nil
    }

    /// 弹出并等它出现。菜单挂在这一项自己的子树下，不在程序坞根节点上。
    private static func show(_ item: AXUIElement) -> AXUIElement? {
        guard AXUIElementPerformAction(item, kAXShowMenuAction as CFString) == .success else {
            return nil
        }
        for _ in 0..<Int(timeout / step) {
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            if let shown = copy(item, "AXShownMenuUIElement"),
               CFGetTypeID(shown) == AXUIElementGetTypeID() {
                return (shown as! AXUIElement)
            }
        }
        // AXShowMenu 已经成功但属性迟迟没出现时，尽力收掉可能仍留在屏幕上的菜单。
        AXUIElementPerformAction(item, kAXCancelAction as CFString)
        return nil
    }

    private static func submenu(of entry: AXUIElement) -> AXUIElement? {
        guard let child = (copy(entry, kAXChildrenAttribute) as? [AXUIElement] ?? []).first,
              copy(child, kAXRoleAttribute) as? String == "AXMenu" else { return nil }
        return child
    }

    /// 条目是延后填的，等它非空。
    private static func entries(of menu: AXUIElement) -> [AXUIElement] {
        let target = copy(menu, kAXRoleAttribute) as? String == "AXMenu" ? menu : submenu(of: menu)
        guard let target else { return [] }
        for _ in 0..<Int(timeout / step) {
            let children = copy(target, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if !children.isEmpty { return children }
            RunLoop.current.run(until: Date().addingTimeInterval(step))
        }
        return []
    }

    private static func read(_ entry: AXUIElement, path: [String]) -> Item? {
        guard let title = copy(entry, kAXTitleAttribute) as? String, !title.isEmpty else { return nil }
        let here = path + [title]
        let children = submenu(of: entry).map { menu in
            entries(of: menu).compactMap { read($0, path: here) }
        } ?? []
        return Item(title: title,
                    enabled: copy(entry, kAXEnabledAttribute) as? Bool ?? true,
                    checked: copy(entry, "AXMenuItemMarkChar") != nil,
                    path: here,
                    children: children)
    }

    private static func copy(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            ? value : nil
    }
}

private extension DockMenu.Borrowed {
    /// 本地化标题 -> 键
    static let allTitles: [String: DockMenu.Borrowed] = {
        var map: [String: DockMenu.Borrowed] = [:]
        for key in [DockMenu.Borrowed.openAtLogin, .forceQuit] {
            if let title = key.title { map[title] = key }
        }
        return map
    }()
}
