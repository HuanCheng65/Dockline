import DocklineCore
import ScreenCaptureKit
import SwiftUI

/// 窗口缩略图。
///
/// 只在指针停在格子上时抓，不做后台轮询——计划书 §2 的后台轻量约束。
/// 抓不到的情况是正常的（最小化、其他桌面上的窗口可能没有可用的图层），
/// 此时预览只显示标题与 App，不显示一张假的空白图。
@MainActor
final class Thumbnails: ObservableObject {
    @Published private(set) var images: [CGWindowID: NSImage] = [:]
    /// 抓取失败的窗口。记下来是为了让预览卡知道该显示占位说明，而不是一直空着。
    @Published private(set) var unavailable = Set<CGWindowID>()

    private var inFlight = Set<CGWindowID>()

    func capture(_ id: CGWindowID) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task { [weak self] in
            let image = await Self.grab(id)
            guard let self else { return }
            inFlight.remove(id)
            if let image {
                images[id] = image
                unavailable.remove(id)
            } else {
                unavailable.insert(id)
            }
        }
    }

    func forget(_ id: CGWindowID) {
        images[id] = nil
        unavailable.remove(id)
    }

    private static func grab(_ id: CGWindowID) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  window.frame.width > 1, window.frame.height > 1 else { return nil }

            let configuration = SCStreamConfiguration()
            // 缩略图最宽 720px（@2x 的 360pt），够看清版式，也不必为它搬运整屏像素
            let scale = min(1, 720 / window.frame.width)
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: NSSize(width: image.width / 2,
                                                        height: image.height / 2))
        } catch {
            return nil
        }
    }
}

/// 浮层里那张卡。计划书 §3。
///
/// 它有两档：只报名字的一档，和长出缩略图与 App 名的一档。两档是同一棵视图树的两种
/// 尺寸，不是两个控件——两个控件之间只能互相淡入淡出，接不上。同一棵树才谈得上过渡：
/// 浮层贴着条的上沿向上长，标题那一行原地不动，缩略图从它上方展开。
///
/// 名字那一档就是系统程序坞悬停名牌的位置：dock 上的项目自身不带标题，关注哪一项就在
/// 它上方报一次名字。条上按 §3.1 只有需要与兄弟区分的窗口才显示标题，单窗口的 App
/// 那一格只有一个图标；即使显示了，那也是剥掉共同首尾段之后又压过宽度的片段。
///
/// 玻璃、圆角与定位都不归它管，归浮层本身——三个阶段共用同一块。
struct PreviewCard: View {
    let title: String
    /// nil = 只报名字那一档
    let detail: Detail?

    /// 长出来的那一层。窗口相关的东西全在这里，非窗口的项（固定文件夹、废纸篓、
    /// 启动台）因此天然只有名字那一档。
    struct Detail: Equatable {
        let window: IndexedWindow
        let appName: String
        let image: NSImage?
        let unavailable: Bool
    }

    /// 卡片宽度随缩略图的比例变——固定比例的框只会让宽窗口两边留白、窄窗口上下留白。
    static let maxWidth: CGFloat = 252
    static let imageHeight: CGFloat = 136
    /// 太窄了标题排不开
    private static let minWidth: CGFloat = 168
    /// 缩略图四周
    private static let pad: CGFloat = 8
    private static let textPad: CGFloat = 12
    private static let textInset: CGFloat = 9
    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    /// 标题固定占两行的高度，卡片才不会一高一矮（`WindowPanel` 里的卡片同理）
    private static let titleHeight: CGFloat = 32
    private static let appNameHeight: CGFloat = 14
    /// 只报名字那一档的高度
    static let nameHeight: CGFloat = 26
    private static var textHeight: CGFloat {
        textInset * 2 + titleHeight + 2 + appNameHeight
    }

    /// 缩略图的圆角与卡片同心——外圆角减去这一圈内边距，两条弧才是平行的。
    /// 各取各的值会看出两个不相干的圆。
    private static var innerRadius: CGFloat { BarMetrics.barRadius - pad }

    /// 缩略图按原比例装进上界里
    static func imageSize(_ image: NSImage?) -> CGSize {
        let limit = maxWidth - pad * 2
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: minWidth - pad * 2, height: 60)
        }
        let ratio = image.size.width / image.size.height
        let height = min(imageHeight, limit / ratio)
        return CGSize(width: (height * ratio).rounded(), height: height.rounded())
    }

    /// 尺寸由浮层驱动，所以必须算得准，不能交给排版去撑——见 `BarContent` 的浮层一节。
    static func size(title: String, detail: Detail?) -> CGSize {
        guard let detail else {
            let measured = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
            return CGSize(width: min(measured + textPad * 2, maxWidth), height: nameHeight)
        }
        let image = imageSize(detail.image)
        return CGSize(width: min(maxWidth, max(minWidth, image.width + pad * 2)),
                      height: image.height + pad * 2 + textHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail { thumbnail(detail) }
            VStack(alignment: .leading, spacing: 2) {
                // 两档共用这一个 Text。换成两个，它们之间就只剩淡入淡出可做了。
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(detail == nil ? 1 : 2)
                    .truncationMode(.tail)
                    .frame(height: detail == nil ? Self.nameHeight : Self.titleHeight,
                           alignment: detail == nil ? .center : .topLeading)
                if let detail {
                    Text(detail.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.appNameHeight, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.textPad)
            .padding(.vertical, detail == nil ? 0 : Self.textInset)
        }
    }

    private func thumbnail(_ detail: Detail) -> some View {
        let size = Self.imageSize(detail.image)
        return ZStack {
            if let image = detail.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(detail.unavailable
                     ? (detail.window.minimized ? "窗口已最小化，暂时无法预览"
                                                : "此窗口暂时无法预览")
                     : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous))
        .background(.quaternary,
                    in: RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous))
        .padding(Self.pad)
        .frame(maxWidth: .infinity)
    }
}

/// 簇的悬停面板（计划书 §3）。
///
/// 与条同一块材质、同一个圆角、同一套格子语法（图标、标题、悬停底色），只多一张缩略图。
/// 面板是簇那一格「另一种姿态」，不是另一种控件——所以它从那一格的位置长出来，
/// 收回时缩回同一个点。
///
/// 面板里不再另开预览卡：缩略图已经在眼前了。
/// 一排窗口的浮层：簇的面板与溢出区的面板共用它。
///
/// 两者的语法必须一样——都是「缩略图 + 两行标题」的格子；不一样的只有表头：
/// 簇有用户挑的色线，溢出区没有（它是条自己的控件，不是用户建的容器）。
struct WindowPanel: View {
    let windows: [BarWindow]
    let heading: String
    let subheading: String
    /// nil = 溢出区
    let color: ClusterColor?
    /// 可用宽度。成员数是无界的（溢出区尤其），排不下要折行。
    let available: CGFloat
    @ObservedObject var thumbnails: Thumbnails
    let icon: (BarWindow) -> NSImage?
    let hovered: (CGWindowID) -> Bool
    let onHover: (CGWindowID, Bool) -> Void
    let onRecall: (IndexedWindow) -> Void
    /// 每张卡片在根坐标系里的位置，供右键落点判定；消失时传 nil
    let onMenuZone: (CGWindowID, CGRect?) -> Void
    let metrics: BarMetrics
    let drag: DragBinding



    private static let thumbWidth: CGFloat = 116
    private static let thumbHeight: CGFloat = 66
    private static let cardPadding: CGFloat = 5
    private static let gap: CGFloat = 5
    private static let inset: CGFloat = 9
    private static let headerHeight: CGFloat = 16
    private static let cardRadius: CGFloat = 12
    /// 缩略图圆角与卡片同心：外圆角减去这一圈内边距，两条弧才平行
    private static var thumbRadius: CGFloat { cardRadius - cardPadding }
    /// 两行标题固定占两行的高度，卡片才不会一高一矮
    private static let titleHeight: CGFloat = 30

    private static var cardWidth: CGFloat { thumbWidth + cardPadding * 2 }
    private static var rowHeight: CGFloat { thumbHeight + 4 + titleHeight + cardPadding * 2 }

    /// 一行最多放几个。
    static func columns(_ count: Int, available: CGFloat) -> Int {
        let room = Int((available - inset * 2 + gap) / (cardWidth + gap))
        return max(1, min(count, room))
    }

    static func rows(_ count: Int, available: CGFloat) -> Int {
        let columns = columns(count, available: available)
        return max(1, (count + columns - 1) / columns)
    }

    static func height(_ count: Int, available: CGFloat) -> CGFloat {
        let rows = rows(count, available: available)
        return inset * 2 + headerHeight + gap * CGFloat(rows)
            + rowHeight * CGFloat(rows)
    }

    static func width(_ count: Int, available: CGFloat) -> CGFloat {
        inset * 2 + cardsWidth(columns(count, available: available))
    }

    private static func cardsWidth(_ count: Int) -> CGFloat {
        CGFloat(count) * cardWidth + gap * CGFloat(max(count - 1, 0))
    }

    var body: some View {
        // 玻璃、圆角与定位归浮层本身，这里只出内容——三个阶段共用同一块
        panel
        .task(id: windows.map(\.id)) {
            while !Task.isCancelled {
                for cell in windows { thumbnails.capture(cell.id) }
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
    }

    private var columns: Int { Self.columns(windows.count, available: available) }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            header
            ForEach(Array(stride(from: 0, to: windows.count, by: columns)), id: \.self) { start in
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(windows[start..<min(start + columns, windows.count)]) { cell in
                        card(cell)
                            .dragged(as: .window(cell.id), metrics: metrics, drag: drag)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Self.inset)
        .frame(width: Self.width(windows.count, available: available),
               height: Self.height(windows.count, available: available),
               alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let color {
                Capsule().fill(color.tint)
                    .frame(width: 14, height: BarMetrics.dotSize)
            }
            Text(heading)
                .font(.system(size: BarMetrics.labelFontSize, weight: .medium))
                .lineLimit(1)
            Text(subheading)
                .font(.system(size: BarMetrics.labelFontSize - 1))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Self.cardsWidth(columns), height: Self.headerHeight, alignment: .leading)
    }

    private func card(_ cell: BarWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail(cell)
            Text(cell.window.title)
                .font(.system(size: BarMetrics.labelFontSize, weight: .medium))
                .lineLimit(BarMetrics.labelLines)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(width: Self.thumbWidth, height: Self.titleHeight, alignment: .topLeading)
        }
        .padding(Self.cardPadding)
        .background { BackingFill(backing: hovered(cell.id) ? .light : .none,
                                  radius: Self.cardRadius) }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BarContent.rootSpace)) }
            action: { onMenuZone(cell.id, $0) }
        .onDisappear { onMenuZone(cell.id, nil) }
        .onHover { onHover(cell.id, $0) }
        .onTapGesture { onRecall(cell.window) }
    }

    private func thumbnail(_ cell: BarWindow) -> some View {
        ZStack {
            if let image = thumbnails.images[cell.id] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if thumbnails.unavailable.contains(cell.id) {
                Text(cell.window.minimized ? "已最小化" : "暂时无法预览")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.thumbRadius, style: .continuous))
        .background(.quaternary,
                    in: RoundedRectangle(cornerRadius: Self.thumbRadius, style: .continuous))
        // App 图标压在缩略图一角：一眼看出这是谁的窗口，与条上的格子同一套读法
        .overlay(alignment: .bottomLeading) {
            AppIcon(image: icon(cell), size: 20, minimized: cell.window.minimized)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(4)
        }
    }
}
