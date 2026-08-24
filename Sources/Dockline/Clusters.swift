import AppKit
import SwiftUI

/// 簇的颜色记号（计划书 §3）。创建时轮流分配，右键可改。
///
/// 取名沿用访达标签的说法，用户认得。
enum ClusterColor: Int, CaseIterable, Identifiable {
    case red = 0, orange, yellow, green, blue, purple, pink, gray

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .gray: return "灰色"
        }
    }

    var tint: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

/// 捏合成簇（计划书 §3）。
///
/// 簇是 Dock 上唯一的聚合形态，且只能由用户亲手创建——看到一个簇就知道是有人
/// 刻意组织过的。它在条上永远是折叠的一格：单击整体开关，悬停浮出面板取用其中之一。
///
/// 成员是**窗口**，不是 App。同一个 App 的另外几个窗口不该被顺带拖进来——
/// 「我在做的这件事」由哪几个窗口组成，只有用户自己知道。
///
/// 只在会话内有效：成员是窗口，窗口本身就不跨重启，名字与颜色也就没有跨重启的落点。
final class ClusterStore {
    struct Cluster {
        var windows: [CGWindowID]
        /// nil = 没起名字，标题第一行退回封面窗口的标题
        var name: String?
        var color: ClusterColor
        /// 条上要不要显示簇名。默认不显示——见计划书 §3「簇的形态」：
        /// 显示了，簇格就和一个带标题的窗口格一样宽，聚簇也就压不出空间来。
        var showsName: Bool
    }

    private(set) var contents: [Int: Cluster] = [:]
    private var nextID = 1

    func cluster(_ id: Int) -> Cluster? { contents[id] }
    func members(of id: Int) -> [CGWindowID] { contents[id]?.windows ?? [] }

    func clusterID(of window: CGWindowID) -> Int? {
        contents.first { $0.value.windows.contains(window) }?.key
    }

    /// 把一批窗口并进目标窗口所在的簇；目标还不在簇里就新建一个。返回簇的 id。
    func merge(_ windows: [CGWindowID], intoWindow target: CGWindowID) -> Int {
        for window in windows { detach(window) }
        if let id = clusterID(of: target) {
            contents[id]?.windows.append(contentsOf: windows)
            return id
        }
        let id = nextID
        nextID += 1
        contents[id] = Cluster(windows: [target] + windows, name: nil, color: freshColor(),
                               showsName: false)
        return id
    }

    func merge(_ windows: [CGWindowID], intoCluster id: Int) {
        for window in windows { detach(window) }
        contents[id]?.windows.append(contentsOf: windows)
    }

    func detach(_ window: CGWindowID) {
        for (id, cluster) in contents where cluster.windows.contains(window) {
            contents[id]?.windows = cluster.windows.filter { $0 != window }
        }
        dissolveSingletons()
    }

    func rename(_ id: Int, to name: String?) {
        contents[id]?.name = name?.isEmpty == true ? nil : name
    }

    func recolor(_ id: Int, to color: ClusterColor) {
        contents[id]?.color = color
    }

    func toggleName(_ id: Int) {
        contents[id]?.showsName.toggle()
    }

    func dissolve(_ id: Int) {
        contents[id] = nil
    }

    /// 每次重建时对齐现实：关掉的窗口出组，剩一个成员的簇解散。
    func prune(present: Set<CGWindowID>) {
        for (id, cluster) in contents {
            contents[id]?.windows = cluster.windows.filter { present.contains($0) }
        }
        dissolveSingletons()
    }

    /// 优先挑还没被别的簇占用的颜色，用完再从头轮
    private func freshColor() -> ClusterColor {
        let used = Set(contents.values.map(\.color))
        return ClusterColor.allCases.first { !used.contains($0) }
            ?? ClusterColor.allCases[contents.count % ClusterColor.allCases.count]
    }

    private func dissolveSingletons() {
        for (id, cluster) in contents where cluster.windows.count <= 1 { contents[id] = nil }
    }
}
