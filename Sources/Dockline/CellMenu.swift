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
            guard let window = windows.first(where: { $0.id == wid }) else { return nil }
            addWindow(window, to: menu)
            return menu
        }
        guard let item = barItems.first(where: { $0.id == id }) else { return nil }
        switch item {
        case .launcher(let url):
            menu.addItem(ActionItem("打开") { [weak self] in self?.open(url) })
            menu.addItem(ActionItem("更改…") { [weak self] in self?.chooseLauncher() })
            addGlobal(to: menu)
        case .folder(let url):
            menu.addItem(ActionItem("打开") { [weak self] in self?.open(url) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("从 Dockline 中移除") { [weak self] in self?.removeFolder(url) })
        case .trash:
            menu.addItem(ActionItem("打开") { [weak self] in
                guard let self else { return }
                open(trashURL)
            })
            menu.addItem(ActionItem("清倒废纸篓…", enabled: trashFull) { [weak self] in
                self?.emptyTrash()
            })
        case .cluster(let cluster):
            addCluster(cluster, to: menu)
        case .window(let cell):
            addWindow(cell.window, to: menu)
        case .dormant(let app):
            menu.addItem(ActionItem("打开") { [weak self] in self?.launch(app) })
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
        menu.addItem(ActionItem("铺满") { [weak self] in self?.fill(cell) })
        menu.addItem(ActionItem("关闭窗口") { [weak self] in self?.close(cell) })
        if clusters.clusterID(of: cell.id) != nil {
            menu.addItem(ActionItem("移出编组") { [weak self] in self?.detachFromCluster(cell.id) })
        }
        let others = clusterChoices.filter { $0.id != clusters.clusterID(of: cell.id) }
        if !others.isEmpty {
            let join = NSMenuItem(title: "加入编组", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for choice in others {
                sub.addItem(ActionItem(choice.name) { [weak self] in
                    self?.addToCluster(cell.id, choice.id)
                })
            }
            join.submenu = sub
            menu.addItem(join)
        }
        if windowCount(pid: cell.pid) > 1 {
            menu.addItem(ActionItem("前置全部窗口") { [weak self] in self?.raiseAll(pid: cell.pid) })
        }
        menu.addItem(.separator())
        addApp(pid: cell.pid, bundleID: cell.bundleID, url: appURL(pid: cell.pid), to: menu)
    }

    /// App 级的那一段。窗口格与无窗口的槽位共用——同一个 App，菜单的下半截就该一样。
    /// 项目与次序取自系统程序坞。
    private func addApp(pid: pid_t?, bundleID: String?, url: URL?, to menu: NSMenu) {
        // App 自己生成的那一段。只有运行中的 App 才有，且要拿得到它的包路径。
        let dynamic = pid.flatMap { pid in
            url.map { url in
                DockMenu.fetch(app: url.path,
                               windowTitles: Set(windows.filter { $0.pid == pid }.map(\.title)))
            }
        } ?? DockMenu.Result()
        for item in dynamic.own {
            menu.addItem(entry(item, app: url))
        }
        if !dynamic.own.isEmpty { menu.addItem(.separator()) }

        let options = NSMenuItem(title: "选项", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if let bundleID {
            sub.addItem(ActionItem("保留在 Dockline 中", checked: pins.isPinned(bundleID)) {
                [weak self] in self?.togglePin(bundleID)
            })
        }
        if let login = dynamic.borrowed[.openAtLogin], let url {
            sub.addItem(entry(login, app: url))
        }
        if let url {
            sub.addItem(ActionItem("在访达中显示") { [weak self] in self?.revealInFinder(url) })
        }
        if !sub.items.isEmpty {
            options.submenu = sub
            menu.addItem(options)
        }
        guard let pid else { return }
        menu.addItem(ActionItem(isHidden(pid: pid) ? "取消隐藏" : "隐藏") { [weak self] in
            self?.toggleHidden(pid: pid)
        })
        menu.addItem(ActionItem("退出") { [weak self] in self?.quit(pid: pid) })
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
        menu.addItem(ActionItem("重新命名…") { [weak self] in self?.renameCluster(cluster.id) })
        menu.addItem(ActionItem("显示簇名", checked: cluster.showsName) { [weak self] in
            self?.toggleClusterName(cluster.id)
        })
        let colors = NSMenuItem(title: "颜色", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for color in ClusterColor.allCases {
            sub.addItem(ActionItem(color.name, checked: color == cluster.color) { [weak self] in
                self?.recolorCluster(cluster.id, to: color)
            })
        }
        colors.submenu = sub
        menu.addItem(colors)
        menu.addItem(.separator())
        for cell in cluster.windows {
            menu.addItem(ActionItem("移出「\(cell.window.title)」") { [weak self] in
                self?.detachFromCluster(cell.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("解散编组") { [weak self] in self?.dissolveCluster(cluster.id) })
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
        menu.addItem(ActionItem("设置…") { [weak self] in self?.showSettings() })
        menu.addItem(ActionItem("退出 Dockline") { NSApp.terminate(nil) })
    }
}
