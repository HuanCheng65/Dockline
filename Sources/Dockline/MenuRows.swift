import AppKit
import SwiftUI

/// 菜单里那些**该是图形的**项。
///
/// 菜单里的项分两类：动作类（关闭、隐藏、退出）本来就是动词，文字是最好的编码；
/// 选择类（落点、颜色）要表达的是一个形状、一块颜色，写成句子等于把图形压成文字、
/// 再让读者解回去。macOS 自己就是这么分的——绿灯悬停菜单里落点是一格格示意图，
/// 访达右键菜单顶上标记是一排色点，都没有一个字。
///
/// 承载方式是 `NSMenuItem.view`（访达那排标记同样如此）。**不自绘整个菜单**：
/// 原生菜单的键盘导航、子菜单开合、贴边翻转、以及从程序坞借来的那段动态项都是白拿的，
/// 自绘要一样样重做。代价是挂了自定义视图的项高亮得自己画、键盘方向键选不中它——
/// 这是这条路的既有代价，访达那排标记也一样。
enum MenuRows {
    /// 一排落点。点中当前已经贴合的那一个即还原（见 `Maximizer.toggle`）。
    static func spots(current: Maximizer.Spot?,
                      pick: @escaping (Maximizer.Spot) -> Void) -> NSMenuItem {
        item(SpotRow(current: current, pick: pick))
    }

    /// 一排色点。
    static func colors(current: ClusterColor,
                       pick: @escaping (ClusterColor) -> Void) -> NSMenuItem {
        item(SwatchRow(current: current, pick: pick))
    }

    /// 簇的色点，给菜单项当图标用。条上簇本来就靠色线认，这里是同一套记号。
    static func dot(_ color: ClusterColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color.tint).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }

    private static func item(_ content: some View) -> NSMenuItem {
        let item = NSMenuItem()
        // 视图自己要知道所属的菜单，才能在点完之后把菜单收掉。项强持有视图，
        // 所以这个回指必须是弱的，否则每右键一次就漏一份菜单。
        let host = NSHostingView(
            rootView: AnyView(content.environment(\.owningItem, Weak(item))))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        item.view = host
        return item
    }
}

/// 点完要把菜单收掉，而收掉的方法是对它所属的 NSMenu 发 `cancelTracking`。
/// 视图在构造时还拿不到那个菜单（项这时还没加进去），所以传项、用时再问它要。
private struct Weak {
    weak var item: NSMenuItem?
    init(_ item: NSMenuItem? = nil) { self.item = item }
}

private struct OwningItemKey: EnvironmentKey {
    static let defaultValue = Weak()
}

private extension EnvironmentValues {
    var owningItem: Weak {
        get { self[OwningItemKey.self] }
        set { self[OwningItemKey.self] = newValue }
    }
}

/// 一行里每一格的公共外壳：尺寸、悬停底、点击收菜单。
private struct MenuCell<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @Environment(\.owningItem) private var owner
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.12 : 0))
            }
            .onHover { hovering = $0 }
            .help(help)
            .onTapGesture {
                // 先收菜单再动手：动作会前置窗口、切 Space，菜单还开着的话会跟着闪。
                owner.item?.menu?.cancelTracking()
                action()
            }
    }
}

/// 落点的地图。**它不是一排图标，是一张屏幕的地图**：每一格在网格里的位置，正好就是
/// 它代表的那块区域，位置与图形互相印证，找左上角不必去解读字形。
///
/// 字形取自系统（见 `Maximizer.Spot.symbol`）——那是 Apple 为「窗口占屏幕的哪一块」
/// 画的一整套，九个天生一致；自己画一套，粗细、圆角、内缩三样都得逐个对，还对不齐。
///
/// 排布直接读 `Spot.allCases` 的次序，按 `Spot.columns` 切行，不在这里另写一份。
private struct SpotRow: View {
    let current: Maximizer.Spot?
    let pick: (Maximizer.Spot) -> Void

    private static let glyph: CGFloat = 18

    private var rows: [[Maximizer.Spot]] {
        stride(from: 0, to: Maximizer.Spot.allCases.count, by: Maximizer.Spot.columns).map {
            Array(Maximizer.Spot.allCases[$0..<min($0 + Maximizer.Spot.columns,
                                                   Maximizer.Spot.allCases.count)])
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, spot in
                        cell(spot)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func cell(_ spot: Maximizer.Spot) -> some View {
        MenuCell(help: current == spot ? "\(spot.label)（再按一次还原）" : spot.label,
                 action: { pick(spot) }) { hovering in
            Image(systemName: spot.symbol)
                .font(.system(size: Self.glyph))
                // 分层渲染：轮廓与填块各自一档，深浅由系统定，我们只给一个色。
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovering || current == spot
                                 ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(HierarchicalShapeStyle.primary))
        }
    }
}

/// 一排色点。当前那个套一圈，与访达标记那排一致。
private struct SwatchRow: View {
    let current: ClusterColor
    let pick: (ClusterColor) -> Void

    private static let dot: CGFloat = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClusterColor.allCases) { color in
                MenuCell(help: color.name, action: { pick(color) }) { _ in
                    Circle()
                        .fill(color.tint)
                        .frame(width: Self.dot, height: Self.dot)
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(0.9), lineWidth: 1.5)
                                .padding(-2.5)
                                .opacity(color == current ? 1 : 0)
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
