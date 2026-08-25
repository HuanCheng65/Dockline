import AppKit
import DocklineCore
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: World) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Dockline 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SettingsView: View {
    @ObservedObject var model: World

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralTab(model: model) }
            Tab("程序坞", systemImage: "dock.rectangle") { DockTab(model: model) }
            Tab("权限", systemImage: "lock.shield") { PermissionsTab(model: model) }
            Tab("关于", systemImage: "info.circle") { AboutTab() }
        }
        .tabViewStyle(.tabBarOnly)
        .frame(minWidth: 520, minHeight: 420)
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @ObservedObject var model: World

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 Dockline", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }))
            }

            Section("窗口") {
                if model.fillHotKey == nil {
                    Text("在窗口条上右键点按窗口并选择「铺满」，可让它铺满屏幕上可用的区域，"
                         + "再次选择恢复原来的大小。快捷键 ⌃⌥⌘F 已被其他 App 占用，目前不可用。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("在窗口条上右键点按窗口并选择「铺满」，或按 ⌃⌥⌘F，"
                         + "可让它铺满屏幕上可用的区域，再次操作恢复原来的大小。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("让系统排列的窗口避开窗口条", isOn: Binding(
                    get: { model.correctsTiling },
                    set: { model.setCorrectsTiling($0) }))
                Text("使用绿色按钮或系统的窗口排列功能时，窗口会铺到屏幕底部、被窗口条遮挡。"
                     + "开启后，Dockline 会把这类窗口的底边上移。此功能会更改其他 App 的窗口大小，"
                     + "少数 App 可能不受影响。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("外观") {
                LabeledContent("图标大小") {
                    HStack(spacing: 10) {
                        Slider(value: $model.iconSize,
                               in: BarMetrics.minIcon...BarMetrics.maxIcon,
                               step: 1) { editing in
                            if !editing { model.commitIconSize() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.iconSize)) 点")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Button("跟随系统") { model.resetIconSize() }
                    }
                }
                Text("也可以直接拖动窗口条上的分隔线来调整大小。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("标签页始终显示为单格", isOn: Binding(
                    get: { model.foldsTabs },
                    set: { model.setFoldsTabs($0) }))
                Text("使用系统标签页的 App，每个标签平时在窗口条上各占一格。"
                     + "开启后它们合并为一格，悬停可展开取用其中之一。"
                     + "关闭时，窗口条也会在宽度不够的时候自动合并它们。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("启动台") {
                LabeledContent("App") {
                    HStack(spacing: 8) {
                        if let icon = model.icon(app: model.pins.launcher, bundleID: nil) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        }
                        Text(model.displayName(of: model.pins.launcher))
                        Button("更改…") { model.chooseLauncher() }
                    }
                }
                Text("点按窗口条最左侧的图标时打开此 App。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 程序坞

private struct DockTab: View {
    @ObservedObject var model: World

    var body: some View {
        Form {
            Section("系统程序坞") {
                if model.systemDockSuppressed {
                    LabeledContent("状态") {
                        Label("已隐藏", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button("恢复系统程序坞") { model.restoreSystemDock() }
                    Text("恢复后，系统程序坞的位置、自动隐藏、唤出延迟与图标跳动将回到接管前的设置。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("如果已移除 Dockline，可在「终端」中执行以下命令恢复：")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(DockControl.manualRestoreCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("系统程序坞会在指针移到屏幕底部时滑出，与 Dockline 重叠。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("隐藏系统程序坞") { model.suppressSystemDock() }
                    Text("将把系统程序坞移到屏幕左侧、开启自动隐藏、把唤出延迟设为极大值，并关闭图标跳动。"
                         + "移到左侧是因为全屏时底部的唤出无法关闭，只能让它避开 Dockline。"
                         + "原有设置会被记录，可随时恢复。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("显示器") {
                ForEach(NSScreen.screens, id: \.self) { screen in
                    if let display = displayID(screen) {
                        Picker(screen.localizedName, selection: Binding(
                            get: { model.autoHides(on: display) },
                            set: { model.setAutoHides($0, on: display) })) {
                            Text("始终显示").tag(false)
                            Text("自动隐藏").tag(true)
                        }
                    }
                }
                Text("每块显示器各有一条 Dockline，只显示这块屏上的窗口。"
                     + "自动隐藏的那块屏平时不画条，指针压到屏幕底边停一下即可唤出——"
                     + "投影仪、电视这类只用来输出的屏适合这一档。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("保留的 App") {
                if model.pins.pinnedApps.isEmpty {
                    Text("尚未保留任何 App。在窗口条上用力点按或右键点按 App 图标即可保留。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.pins.pinnedApps, id: \.self) { bundleID in
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                        LabeledContent {
                            Button("移除") { model.togglePin(bundleID) }
                        } label: {
                            HStack(spacing: 8) {
                                if let url, let icon = model.icon(app: url, bundleID: bundleID) {
                                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                }
                                Text(url.map { model.displayName(of: $0) } ?? bundleID)
                            }
                        }
                    }
                    Text("保留的 App 会占据固定位置。未打开时显示为图标，打开后在原位展开为窗口。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("文件夹") {
                ForEach(model.pins.folders, id: \.self) { url in
                    LabeledContent {
                        Button("移除") { model.removeFolder(url) }
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = model.icon(file: url) {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            }
                            Text(model.displayName(of: url))
                        }
                    }
                }
                Button("添加文件夹…") { model.addFolder() }
                Text("将文件拖到文件夹上可将其移入该文件夹。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

private struct PermissionsTab: View {
    @ObservedObject var model: World

    var body: some View {
        Form {
            Section {
                PermissionRow(name: "辅助功能",
                              granted: model.accessibility,
                              detail: "用于读取窗口列表并将窗口带到前台。这是 Dockline 的必需权限。",
                              pane: "Privacy_Accessibility")
                PermissionRow(name: "屏幕录制",
                              granted: model.screenRecording,
                              detail: "用于读取其他桌面上窗口的标题。这是 Dockline 的必需权限。",
                              pane: "Privacy_ScreenCapture")
                PermissionRow(name: "自动化",
                              granted: nil,
                              detail: "仅在清倒废纸篓时需要，首次使用时会请求授权。",
                              pane: "Privacy_Automation")
            } header: {
                Text("隐私与安全性")
            } footer: {
                Text("Dockline 不收集任何数据，也不会将信息发送到网络。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let name: String
    /// nil 表示按需授权，无法预先查询状态
    let granted: Bool?
    let detail: String
    let pane: String

    var body: some View {
        LabeledContent {
            Button("前往设置…") {
                guard let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                    switch granted {
                    case true:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case false:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case nil:
                        EmptyView()
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 关于

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let icon = NSImage(named: "Dockline") ?? NSApp.applicationIconImage {
                Image(nsImage: icon).resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Dockline").font(.system(size: 24, weight: .semibold))
            Text("版本 \(version)").foregroundStyle(.secondary)
            Text("按内容检索窗口的程序坞。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
