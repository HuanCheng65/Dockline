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

/// 悬停预览卡。计划书 §3：标题 + App + 实时缩略图。
///
/// 材质与圆角跟条本体走，见下方 background。
struct PreviewCard: View {
    let window: IndexedWindow
    let appName: String
    let scheme: ColorScheme
    let image: NSImage?
    let unavailable: Bool



    /// 卡片宽度随缩略图的比例变——固定比例的框只会让宽窗口两边留白、窄窗口上下留白。
    /// 这两个值是上界，定位时按上界夹屏幕边缘。
    static let width: CGFloat = 252
    static let imageHeight: CGFloat = 136
    /// 太窄了标题排不开
    private static let minWidth: CGFloat = 168

    /// 缩略图按原比例装进上界里
    private var imageSize: CGSize {
        let limit = Self.width - Self.pad * 2
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: Self.minWidth - Self.pad * 2, height: 60)
        }
        let ratio = image.size.width / image.size.height
        let height = min(Self.imageHeight, limit / ratio)
        return CGSize(width: (height * ratio).rounded(), height: height.rounded())
    }

    private var cardWidth: CGFloat {
        min(Self.width, max(Self.minWidth, imageSize.width + Self.pad * 2))
    }

    /// 卡片外圆角与条本体一致；缩略图的圆角与它同心——外圆角减去这一圈内边距，
    /// 两条弧才是平行的。各取各的值会看出两个不相干的圆。
    private static let pad: CGFloat = 8
    private var innerRadius: CGFloat { BarMetrics.barRadius - Self.pad }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                Text(appName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: cardWidth)
        .environment(\.colorScheme, scheme)
        .background { DockGlass(cornerRadius: BarMetrics.barRadius).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: BarMetrics.barRadius, style: .continuous))
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(unavailable ? placeholder : "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
        .background(.quaternary,
                    in: RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
        .padding(Self.pad)
        .frame(maxWidth: .infinity)
    }

    private var placeholder: String {
        window.minimized ? "窗口已最小化，暂时无法预览" : "此窗口暂时无法预览"
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
    /// 浮层就贴在条的正上方，与条共用同一次背景采样，不再各采一次
    let scheme: ColorScheme
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
        panel
            .environment(\.colorScheme, scheme)
            .background {
                DockGlass(cornerRadius: BarMetrics.barRadius).allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: BarMetrics.barRadius,
                                           style: .continuous))
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
