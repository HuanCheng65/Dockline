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

    /// 上一次枚举拿到的窗口句柄。整份替换、不逐个增删——键就是那一刻系统里的全部窗口，
    /// 关掉的窗口下一次枚举自然掉出去，不必另立一套淘汰规则。
    ///
    /// 缓存它，是因为贵的是枚举而不是抓图：实测枚举中位 41ms、P95 168ms，抓图中位 35ms。
    /// 每抓一张都重新枚举一遍，请求 30Hz 只跑得到 12.5Hz、吃掉 12% 一核；复用句柄是
    /// 27Hz、2% 一核。悬停预览每 1.2 秒刷一次，同样在白付这笔钱。
    private var handles: [CGWindowID: SCWindow] = [:]
    /// 正在跑的那一次枚举。面板要一整排缩略图，同一拍里会有好几格都没命中缓存；
    /// 让它们等同一次枚举，而不是一格枚举一遍。
    private var listing: Task<Void, Never>?

    /// SCK 抓不到、只能走老路的窗口。Space 不在前台的全屏窗口就是这一类。
    ///
    /// 记住它们是为了不在每一帧上白付一次 SCK 的失败（实测 39ms）——大预览一秒二十几帧，
    /// 每帧先失败一次就把帧率砍掉一半。老路对普通窗口同样有效（只是更贵），
    /// 所以一个窗口留在这份名单里不会出错，最多是没走上更省的那条。
    private var legacyOnly: Set<CGWindowID> = []

    func capture(_ id: CGWindowID) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        Task { [weak self] in
            guard let self else { return }
            let image = await grab(id)
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

    // MARK: 大预览那一张（计划书 §6 M6）
    //
    // 单独放，不进 `images`：它按屏幕尺寸抓，一张十几 MB，而 `images` 是按窗口累积的。
    // 松手即丢，任何时刻只留一张。

    @Published private(set) var large: NSImage?
    private var largeID: CGWindowID?

    func beginLarge(_ id: CGWindowID) {
        guard largeID != id else { return }
        largeID = id
        large = nil
    }

    func endLarge() {
        largeID = nil
        large = nil
    }

    /// 抓一张大的。调用方自己一轮接一轮地调，不另设节拍——抓图本身约 35ms，
    /// 它自己就是限速器；排一个比抓图还密的节拍只会让请求堆起来。
    @discardableResult
    func captureLarge(_ id: CGWindowID, width: CGFloat) async -> Bool {
        guard let image = await grab(id, width: width) else { return false }
        // 松手之后才回来的那一张要丢掉，否则下一次大预览开场会闪一帧上一个窗口
        guard largeID == id else { return true }
        large = image
        return true
    }

    private func grab(_ id: CGWindowID, width: CGFloat = Thumbnails.thumbWidth) async -> NSImage? {
        if legacyOnly.contains(id) { return await Self.legacyShot(id, width: width) }
        if let image = await sck(id, width: width) { return image }
        // SCK 合成的是「当前正在显示的一帧」，Space 不在前台的全屏窗口它给不出来。
        // 那类窗口正是最该看一眼的一批，所以换一条路再问一次，见 `WindowShot`。
        guard let image = await Self.legacyShot(id, width: width) else { return nil }
        legacyOnly.insert(id)
        return image
    }

    private func sck(_ id: CGWindowID, width: CGFloat) async -> NSImage? {
        let cached = handles[id]
        if cached == nil { await list() }
        guard let handle = handles[id] else { return nil }
        if let image = await Self.shoot(handle, id: id, width: width) { return image }
        // 句柄是上一次枚举时拿的，窗口关掉又新建就作废了。整个类只有这一处重来：
        // 重新枚举、拿新句柄再抓一张，还失败才是真的抓不到。刚枚举出来的句柄不重来
        // ——那只会把同一次失败原样再跑一遍。
        guard cached != nil else { return nil }
        await list()
        guard let fresh = handles[id] else { return nil }
        return await Self.shoot(fresh, id: id, width: width)
    }

    /// 老路那一张。**必须挪出主线程。**
    ///
    /// 它整段是同步的，而且贵——取整幅原始像素回来，再自己缩一次。留在主线程上跑，
    /// 大预览一秒二十几帧就把主线程占满，整条 bar 当场没反应（实测 `sample`：主线程
    /// 1939 个样本里 1937 个在 `CGContextDrawImage` 里）。`nonisolated` 只是说它不需要
    /// 这个 actor，不代表它会换个线程跑——从主 actor 直接调，它就在主线程上跑。
    ///
    /// 挪出去顺带解决第二件事：这个 `await` 从此**真的会挂起一次**。采集循环靠它把
    /// 主线程让出来，一个不挂起的 await 是让不出去的。
    private static func legacyShot(_ id: CGWindowID, width: CGFloat) async -> NSImage? {
        let shot = Task.detached(priority: .userInitiated) { () -> CGImage? in
            WindowShot.grab(id, width: width)
        }
        guard let image = await shot.value else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2,
                                                    height: image.height / 2))
    }

    private func list() async {
        if let listing { return await listing.value }
        let task = Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false) else { return }
            var fresh: [CGWindowID: SCWindow] = [:]
            for window in content.windows { fresh[window.windowID] = window }
            handles = fresh
            // 走老路的那份名单跟着一起收：键都是同一批窗口，关掉的自然掉出去
            legacyOnly.formIntersection(fresh.keys)
        }
        listing = task
        await task.value
        listing = nil
    }

    /// 缩略图最宽 720px（@2x 的 360pt），够看清版式，也不必为它搬运整屏像素。
    /// 大预览那一档由调用方按屏幕给出自己的宽度。
    private nonisolated static let thumbWidth: CGFloat = 720

    private static func shoot(_ window: SCWindow, id: CGWindowID,
                              width: CGFloat) async -> NSImage? {
        // 输出尺寸必须按窗口此刻的几何算，不能用句柄里那份快照：句柄缓存着不动，窗口
        // 却会改尺寸，比例一对不上，抓回来的图就缩在缓冲区一角、其余是空白。
        // 单窗口的这次查询是微秒级的，与枚举整份可共享内容不是一回事。
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
                as? [[String: Any]],
              let dictionary = raw.first?[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              bounds.width > 1, bounds.height > 1 else { return nil }

        let configuration = SCStreamConfiguration()
        let scale = min(1, width / bounds.width)
        configuration.width = Int(bounds.width * scale)
        configuration.height = Int(bounds.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2,
                                                    height: image.height / 2))
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
    /// 大预览那一档能占的最大范围。nil = 还是小卡。
    ///
    /// 由调用方按这条 bar 所在的屏算，不在这里从容器量：容器的高度正是随这张卡长的，
    /// 从它量就成了循环。见 `BarContent.peekBox`。
    let peek: CGSize?

    /// 这一格上有 agent 会话时，卡片要说的东西。nil = 没有会话，卡片还是原来那张。
    ///
    /// 有会话时缩略图**让位**：那扇窗口长什么样此刻不重要，重要的是它里面那件事进行到
    /// 哪一步了。让位而不是拿掉，是为了不分成两张卡——分支一旦出现在带 `.frame` 的那一层，
    /// 尺寸就没有起点可以插值，整块只剩淡入淡出（§3.1 那条教训）。
    let session: Session?

    /// 长出来的那一层。窗口相关的东西全在这里，非窗口的项（固定文件夹、废纸篓、
    /// 启动台）因此天然只有名字那一档。
    struct Detail: Equatable {
        let window: IndexedWindow
        let appName: String
        let image: NSImage?
        let unavailable: Bool
    }

    struct Session: Equatable {
        let agent: String?
        let elapsed: String
        /// 用户这一轮说的话
        let prompt: String?
        /// 此刻的状况，与格子第二行同一句
        let state: String
        let steps: [Activity.Step]
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
    private static func textHeight(showsAppName: Bool) -> CGFloat {
        textInset * 2 + titleHeight + (showsAppName ? 2 + appNameHeight : 0)
    }

    /// App 名与窗口标题一模一样时不报第二遍——「访达 / 访达」两行说的是同一件事。
    /// 窗口只有一个、标题就是 App 名的程序（访达、系统设置、计算器）天天会撞上。
    private static func showsAppName(_ title: String, _ detail: Detail?) -> Bool {
        guard let detail else { return false }
        return detail.appName != title
    }

    /// 缩略图的圆角与卡片同心——外圆角减去这一圈内边距，两条弧才是平行的。
    /// 各取各的值会看出两个不相干的圆。
    private static var innerRadius: CGFloat { BarMetrics.barRadius - pad }

    /// 有会话时的版面。卡片宽度**固定**：近期动作那几行长短不一，跟着它们变宽的话，
    /// 面板会在 agent 每走一步时抖一下。
    static let sessionWidth: CGFloat = 300
    private static let rowHeight: CGFloat = 17
    private static let rowGap: CGFloat = 6

    private static func sessionHeight(_ session: Session) -> CGFloat {
        let prompt = session.prompt == nil ? 0 : rowHeight + 2
        // 近期动作，外加当前状况那一行
        let rows = CGFloat(session.steps.count + 1) * rowHeight
        return prompt + rowGap + rows + textInset
    }

    /// 画面能占的最大范围。各档只差这一个框——尺寸算法与视图树都是同一套。
    private static func imageBox(_ peek: CGSize?, showsAppName: Bool) -> CGSize {
        guard let peek else {
            return CGSize(width: maxWidth - pad * 2, height: imageHeight)
        }
        return CGSize(width: peek.width - pad * 2,
                      height: peek.height - pad * 2 - textHeight(showsAppName: showsAppName))
    }

    /// 有会话时画不画缩略图。
    ///
    /// **平时不画。** 那扇窗口长什么样，此刻不是问题；而一张小图浮在卡片中央、两边留着
    /// 大片空白，比不画难看得多。按住空格要大预览时才画——那时用户是明确要看窗口的，
    /// 而且那一档照旧铺满，会话区跟在下面。
    private static func showsImage(_ session: Session?, _ peek: CGSize?) -> Bool {
        session == nil || peek != nil
    }

    /// 缩略图按原比例装进上界里
    static func imageSize(_ image: NSImage?, box: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: minWidth - pad * 2, height: 60)
        }
        let ratio = image.size.width / image.size.height
        let height = min(box.height, box.width / ratio)
        return CGSize(width: (height * ratio).rounded(), height: height.rounded())
    }

    /// 尺寸由浮层驱动，所以必须算得准，不能交给排版去撑——见 `BarContent` 的浮层一节。
    static func size(title: String, detail: Detail?, peek: CGSize?,
                     session: Session?) -> CGSize {
        guard let detail else {
            let measured = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
            return CGSize(width: min(measured + textPad * 2, maxWidth), height: nameHeight)
        }
        // App 名那一行在会话卡上是噪声：卡片说的是那件事，不是那个程序
        let shows = session == nil && showsAppName(title, detail)
        let draws = showsImage(session, peek)
        let image = draws ? imageSize(detail.image, box: imageBox(peek, showsAppName: shows))
                          : .zero
        let height = (draws ? image.height + pad * 2 : 0) + textHeight(showsAppName: shows)
            + (session.map(sessionHeight) ?? 0)
        // 大预览那一档的宽度照旧由画面定——按住空格是要看窗口，会话卡的固定宽度
        // 不该把它压回去。
        guard session != nil, peek == nil else {
            return CGSize(width: min(peek?.width ?? maxWidth, max(minWidth, image.width + pad * 2)),
                          height: height)
        }
        return CGSize(width: sessionWidth, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail, Self.showsImage(session, peek) { thumbnail(detail) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 6) {
                    // 各档共用这一个 Text。换成两个，它们之间就只剩淡入淡出可做了。
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(detail == nil ? 1 : 2)
                        .truncationMode(.tail)
                    // 无条件挂着，没有会话时是空串：加条件就是加分支，分支一换 identity 就断
                    Text(session.map { [$0.agent, $0.elapsed].compactMap { $0 }
                            .joined(separator: " · ") } ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: detail == nil ? Self.nameHeight : Self.titleHeight,
                       alignment: detail == nil ? .center : .topLeading)
                if let detail, session == nil, Self.showsAppName(title, detail) {
                    Text(detail.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.appNameHeight, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.textPad)
            .padding(.vertical, detail == nil ? 0 : Self.textInset)
            if let session { sessionBlock(session) }
        }
    }

    private func sessionBlock(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let prompt = session.prompt {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: Self.rowHeight, alignment: .topLeading)
                    .padding(.bottom, 2)
            }
            Divider().padding(.vertical, (Self.rowGap - 1) / 2)
            // 旧的在上、当前在下：读起来是一条往下走的时间线，最新的那一行贴着卡片底边，
            // 也就是离条最近的地方。
            ForEach(session.steps) { step in
                Text(step.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: Self.rowHeight, alignment: .topLeading)
            }
            Text(session.state)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: Self.rowHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.textPad)
        .padding(.bottom, Self.textInset)
    }

    private func thumbnail(_ detail: Detail) -> some View {
        let size = Self.imageSize(
            detail.image,
            box: Self.imageBox(peek,
                               showsAppName: session == nil && Self.showsAppName(title, detail)))
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
