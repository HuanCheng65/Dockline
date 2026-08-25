import AppKit
import DocklineCore

/// 带闭包的菜单项。NSMenuItem 只认 target/action，这里把闭包包成一个自持有的项。
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false,
         _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("不从 nib 加载") }

    @objc private func fire() { handler() }
}

/// 右键菜单。
///
/// 走 AppKit 自己弹 NSMenu，不用 SwiftUI 的 `.contextMenu`：后者的内容在**每次重绘**时
/// 求值（实测 8 秒 20 次），而 App 的动态项要在右键那一刻向程序坞现取（见 `DockMenu`）——
/// 挂在那里等于每秒去问好几次，每次还在屏幕上闪一份菜单。NSMenu 是右键那一刻才构造的。
///
/// 取动态项是同步的：实测一轮 45–50ms，低于菜单响应的感知阈值，不值得为它加一套
/// 「先弹占位、异步填充」的机制。真慢下来了再说——NSMenu 支持弹出后改内容，那条路留着。
extension BarModel {
    /// 右键落在条上的某一格，或落在条的空白处。都不是就不弹。
    func menu(at point: CGPoint) -> NSMenu? {
        guard let id = menuZone(at: point) else {
            return barContains(point) ? globalMenu() : nil
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // 浮层里的窗口（簇扇面、标签面板、溢出面板）。它们不在条上，但仍然是窗口，
        // 菜单与条上的格子一致——收进溢出区不该让一个窗口失去它的操作。
        if let wid = Self.panelWindow(id) {
            guard let window = world.windows.first(where: { $0.id == wid }) else { return nil }
            addWindow(window, to: menu)
            return menu
        }
        guard let item = barItems.first(where: { $0.id == id }) else { return nil }
        switch item {
        case .launcher(let url):
            menu.addItem(ActionItem("打开") { [weak self] in self?.world.open(url) })
            menu.addItem(ActionItem("更改…") { [weak self] in self?.world.chooseLauncher() })
            addGlobal(to: menu)
        case .folder(let url):
            menu.addItem(ActionItem("打开") { [weak self] in self?.world.open(url) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("从 Dockline 中移除") { [weak self] in self?.world.removeFolder(url) })
        case .trash:
            menu.addItem(ActionItem("打开") { [weak self] in
                guard let self else { return }
                world.open(world.trashURL)
            })
            menu.addItem(ActionItem("清倒废纸篓…", enabled: world.trashFull) { [weak self] in
                self?.world.emptyTrash()
            })
        case .cluster(let cluster):
            addCluster(cluster, to: menu)
        case .window(let cell):
            addWindow(cell.window, to: menu)
        case .dormant(let app):
            menu.addItem(ActionItem("打开") { [weak self] in self?.world.launch(app) })
            menu.addItem(.separator())
            addApp(pid: app.pid, bundleID: app.bundleID, url: app.url, to: menu)
        case .overflow:
            // 溢出入口是 Dockline 自己的控件，和启动台一样带自身的菜单项
            addGlobal(to: menu, leading: false)
        case .separator, .notice:
            return nil
        }
        return menu
    }

    /// 浮层里的窗口卡登记的 id 形如 `panel.w<窗口号>`，见 `BarContent`。
    private static func panelWindow(_ id: String) -> CGWindowID? {
        guard id.hasPrefix("panel.w") else { return nil }
        return CGWindowID(id.dropFirst("panel.w".count))
    }

    // MARK: 各段

    /// 入参是窗口本身而不是条上的格子：浮层里的窗口没有格子，菜单却该一模一样。
    private func addWindow(_ cell: IndexedWindow, to menu: NSMenu) {
        menu.addItem(ActionItem("铺满") { [weak self] in self?.world.fill(cell) })
        menu.addItem(ActionItem("关闭窗口") { [weak self] in self?.world.close(cell) })
        if world.clusters.clusterID(of: cell.id) != nil {
            menu.addItem(ActionItem("移出编组") { [weak self] in self?.world.detachFromCluster(cell.id) })
        }
        let others = clusterChoices.filter { $0.id != world.clusters.clusterID(of: cell.id) }
        if !others.isEmpty {
            let join = NSMenuItem(title: "加入编组", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for choice in others {
                sub.addItem(ActionItem(choice.name) { [weak self] in
                    self?.world.addToCluster(cell.id, choice.id)
                })
            }
            join.submenu = sub
            menu.addItem(join)
        }
        if world.windowCount(pid: cell.pid) > 1 {
            menu.addItem(ActionItem("前置全部窗口") { [weak self] in self?.world.raiseAll(pid: cell.pid) })
        }
        addMoveToDisplay(cell, to: menu)
        menu.addItem(.separator())
        addApp(pid: cell.pid, bundleID: cell.bundleID, url: world.appURL(pid: cell.pid), to: menu)
    }

    /// 「移到显示器」（计划书 §6 M5）。只在多屏时出现，也不列窗口已经在的那块屏。
    ///
    /// 入口挂在窗口自己那一格上，而不是目标屏的 bar 上——那条 bar 上根本没有这个窗口，
    /// 它归别的屏（§6 M5「对象归属」）。要搬哪个窗口，只有它自己那一格说得清。
    private func addMoveToDisplay(_ cell: IndexedWindow, to menu: NSMenu) {
        let elsewhere = NSScreen.screens.filter { displayID($0) != world.home(of: cell) }
        guard NSScreen.screens.count > 1, !elsewhere.isEmpty else { return }
        let move = NSMenuItem(title: "移到显示器", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for screen in elsewhere {
            guard let id = displayID(screen) else { continue }
            sub.addItem(ActionItem(screen.localizedName) { [weak self] in
                self?.world.move(cell, to: id)
            })
        }
        guard !sub.items.isEmpty else { return }
        move.submenu = sub
        menu.addItem(move)
    }

    /// 「在此显示器打开」（计划书 §6 M5）。本屏没有这个 App 的窗口时，让它在本屏开一个。
    ///
    /// 计划书原话是「按下程序坞动态菜单里的『新建窗口』」，判据是那个 App 有没有声明这一项。
    /// 实做时发现只有前半句成立：那一项是 App 自己生成的，标题也由它自己本地化，
    /// 程序坞的 `DockMenus.strings` 里没有对应的键。要认出「哪一项是新建窗口」，只能维护
    /// 一张各语言的标题表，而那张表一定会漏。于是这里不猜，把该 App 声明的动态项原样列出来，
    /// 由用户点哪一项——「有没有声明」这个判据仍然成立，猜的那一步去掉了。
    private func addOpenHere(pid: pid_t, app url: URL, items: [DockMenu.Item], to menu: NSMenu) {
        guard NSScreen.screens.count > 1, !items.isEmpty, let display else { return }
        guard !world.windows.contains(where: {
            $0.pid == pid && world.home(of: $0) == display
        }) else { return }
        let open = NSMenuItem(title: "在此显示器打开", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for item in items where item.children.isEmpty {
            sub.addItem(ActionItem(item.title, enabled: item.enabled) { [weak self] in
                self?.world.openHere(pid: pid, app: url, item: item, on: display)
            })
        }
        guard !sub.items.isEmpty else { return }
        open.submenu = sub
        menu.addItem(open)
    }

    /// App 级的那一段。窗口格与无窗口的槽位共用——同一个 App，菜单的下半截就该一样。
    /// 项目与次序取自系统程序坞。
    private func addApp(pid: pid_t?, bundleID: String?, url: URL?, to menu: NSMenu) {
        // App 自己生成的那一段。只有运行中的 App 才有，且要拿得到它的包路径。
        let dynamic = pid.flatMap { pid in
            url.map { url in
                DockMenu.fetch(app: url.path,
                               windowTitles: Set(world.windows.filter { $0.pid == pid }.map(\.title)))
            }
        } ?? DockMenu.Result()
        for item in dynamic.own {
            menu.addItem(entry(item, app: url))
        }
        if let pid, let url { addOpenHere(pid: pid, app: url, items: dynamic.own, to: menu) }
        if !dynamic.own.isEmpty { menu.addItem(.separator()) }

        let options = NSMenuItem(title: "选项", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if let bundleID {
            sub.addItem(ActionItem("保留在 Dockline 中", checked: world.pins.isPinned(bundleID)) {
                [weak self] in self?.world.togglePin(bundleID)
            })
        }
        if let login = dynamic.borrowed[.openAtLogin], let url {
            sub.addItem(entry(login, app: url))
        }
        if let url {
            sub.addItem(ActionItem("在访达中显示") { [weak self] in self?.world.revealInFinder(url) })
        }
        if !sub.items.isEmpty {
            options.submenu = sub
            menu.addItem(options)
        }
        guard let pid else { return }
        menu.addItem(ActionItem(world.isHidden(pid: pid) ? "取消隐藏" : "隐藏") { [weak self] in
            self?.world.toggleHidden(pid: pid)
        })
        menu.addItem(ActionItem("退出") { [weak self] in self?.world.quit(pid: pid) })
        if let force = dynamic.borrowed[.forceQuit], let url {
            menu.addItem(entry(force, app: url))
        }
    }

    /// 一条来自程序坞的项。按下时重新弹一次程序坞的菜单、找到同一条按下去。
    private func entry(_ item: DockMenu.Item, app url: URL?) -> NSMenuItem {
        guard item.children.isEmpty else {
            let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for child in item.children { sub.addItem(entry(child, app: url)) }
            parent.submenu = sub
            return parent
        }
        return ActionItem(item.title, enabled: item.enabled, checked: item.checked) {
            guard let url else { return }
            DockMenu.press(app: url.path, at: item.path)
        }
    }

    private func addCluster(_ cluster: BarCluster, to menu: NSMenu) {
        menu.addItem(ActionItem("重新命名…") { [weak self] in self?.world.renameCluster(cluster.id) })
        menu.addItem(ActionItem("显示簇名", checked: cluster.showsName) { [weak self] in
            self?.world.toggleClusterName(cluster.id)
        })
        let colors = NSMenuItem(title: "颜色", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for color in ClusterColor.allCases {
            sub.addItem(ActionItem(color.name, checked: color == cluster.color) { [weak self] in
                self?.world.recolorCluster(cluster.id, to: color)
            })
        }
        colors.submenu = sub
        menu.addItem(colors)
        menu.addItem(.separator())
        for cell in cluster.windows {
            menu.addItem(ActionItem("移出「\(cell.window.title)」") { [weak self] in
                self?.world.detachFromCluster(cell.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("解散编组") { [weak self] in self?.world.dissolveCluster(cluster.id) })
    }

    /// Dockline 自身的项。只出现在启动台（Dockline 自己的部件）和条的空白处——窗口格与
    /// App 槽位代表的是别的 App，把「退出 Dockline」摆进去容易被误点成「退出那个 App」。
    private func globalMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addGlobal(to: menu, leading: false)
        return menu
    }

    private func addGlobal(to menu: NSMenu, leading: Bool = true) {
        if leading { menu.addItem(.separator()) }
        menu.addItem(ActionItem("设置…") { [weak self] in self?.world.showSettings() })
        menu.addItem(ActionItem("退出 Dockline") { NSApp.terminate(nil) })
    }
}
