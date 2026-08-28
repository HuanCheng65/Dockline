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

    /// 这一格上有状态时，卡片要说的东西。nil = 什么都没有，卡片还是原来那张。
    ///
    /// 有状态时缩略图**让位**：那扇窗口长什么样此刻不重要，重要的是它里面那件事进行到
    /// 哪一步了、或者在放什么。让位而不是拿掉，是为了不分成两张卡——分支一旦出现在带
    /// `.frame` 的那一层，尺寸就没有起点可以插值，整块只剩淡入淡出（§3.1 那条教训）。
    ///
    /// **两种状态共用这一棵视图树，各写各的下半截。** 会话的时间线和播放器没有一处能
    /// 共用，硬套一个模板只会得到两边都不称职的一张卡；但外壳、标题行与尺寸协议是共用的，
    /// 否则从一个普通窗口格滑到音乐格就成了两张卡对着淡。
    let content: CellStatus?

    /// 用户在这张卡上批了或驳了一次授权。
    let onAnswer: (UUID, Bool) -> Void
    /// 用户按了播放控制。
    let onMedia: (MediaCommand) -> Void

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
    /// 标题那一行占多高。名字那一档一行居中；窗口标题排两行；会话名只有一行。
    private static func headHeight(detail: Detail?, content: CellStatus?) -> CGFloat {
        guard content == nil else { return sessionTitleHeight }
        return detail == nil ? nameHeight : titleHeight
    }

    /// 只报名字那一档：没有窗口可预览，这一格上也没有状态可说。
    ///
    /// **不等于 `detail == nil`。** 窗口全关之后那一格照旧有状态（见 §5.4），
    /// 它没有缩略图可给，但要说的东西和窗口格上的一样多。
    private static func isPill(_ detail: Detail?, _ content: CellStatus?) -> Bool {
        detail == nil && content == nil
    }

    private var pill: Bool { Self.isPill(detail, content) }

    private static func textHeight(showsAppName: Bool, content: CellStatus?) -> CGFloat {
        textInset * 2 + (content == nil ? titleHeight : sessionTitleHeight)
            + (showsAppName ? 2 + appNameHeight : 0)
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
    /// 会话卡的标题只有一行。窗口标题排两行是因为它长，而会话名短——沿用两行的高度，
    /// 标题底下会空出一整行，那正是这张卡最早看着松垮的原因。
    private static let sessionTitleHeight: CGFloat = 22
    private static let rowHeight: CGFloat = 18
    private static let rowGap: CGFloat = 8
    /// 动作名那一栏的宽度。固定住，三行的动作名才竖直对齐——对齐是这张卡读起来
    /// 像一张表而不是三句话的全部原因。
    private static let verbWidth: CGFloat = 46
    /// 图标那一栏。定宽，几行的动作名才从同一个横坐标起头。
    private static let symbolWidth: CGFloat = 14
    /// 步数那一行
    private static let countHeight: CGFloat = 16

    /// 卡片里能排字的宽度
    private static var innerWidth: CGFloat { sessionWidth - textPad * 2 }
    private static let bodyFont = NSFont.systemFont(ofSize: 11)
    /// 提示词与回复各自最多占几行。再多就不是「一眼看清」，而是要读的东西了。
    private static let promptLines = 3
    private static let responseLines = 7

    /// 授权那一段里，要判断的内容每行占多高。
    ///
    /// 这些行**不折行**，一行就是一行——一条折了行的 diff 读起来比截断还糟。
    /// 每行都钉死高度，这一段因此是算出来的而不是量出来的：卡片尺寸由浮层驱动、
    /// 必须提前算准，而定高的行不需要经过量文字那条容易出错的路。
    private static let askLineHeight: CGFloat = 15
    private static let askBoxPad: CGFloat = 5
    private static let buttonHeight: CGFloat = 30

    /// 画面能占的最大范围。各档只差这一个框——尺寸算法与视图树都是同一套。
    private static func imageBox(_ peek: CGSize?, showsAppName: Bool,
                                 content: CellStatus?) -> CGSize {
        guard let peek else {
            return CGSize(width: maxWidth - pad * 2, height: imageHeight)
        }
        return CGSize(width: peek.width - pad * 2,
                      height: peek.height - pad * 2
                          - textHeight(showsAppName: showsAppName, content: content))
    }

    /// 有会话时画不画缩略图。
    ///
    /// **平时不画。** 那扇窗口长什么样，此刻不是问题；而一张小图浮在卡片中央、两边留着
    /// 大片空白，比不画难看得多。按住空格要大预览时才画——那时用户是明确要看窗口的，
    /// 而且那一档照旧铺满，会话区跟在下面。
    private static func showsImage(_ content: CellStatus?, _ peek: CGSize?) -> Bool {
        content == nil || peek != nil
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

    /// 这一档有多宽。
    ///
    /// **只剩宽度还要在这里定。** 高度已经交给排版自己长——玻璃跟着内容量出来的尺寸走
    /// （见 `GlassRuler`），先前那套与视图树平行的高度算法（折行、授权段、动作行逐条累加）
    /// 整个不需要了。而宽度不是排出来的，它是一条设计约束：名字那一档跟着文字走并封顶，
    /// 会话与播放固定一个宽度好让几行对齐，预览卡跟着画面的比例走。
    ///
    /// nil = 不定宽，由文字自己撑，上限交给 `maxWidth`。
    private var width: CGFloat? {
        if pill { return nil }
        let draws = detail != nil && Self.showsImage(content, peek)
        // 大预览那一档的宽度照旧由画面定——按住空格是要看窗口，会话卡的固定宽度
        // 不该把它压回去。
        guard content == nil || draws else { return Self.sessionWidth }
        // App 名那一行在会话卡上是噪声：卡片说的是那件事，不是那个程序
        let shows = content == nil && Self.showsAppName(title, detail)
        let image = Self.imageSize(detail?.image,
                                   box: Self.imageBox(peek, showsAppName: shows, content: content))
        return min(peek?.width ?? Self.maxWidth,
                   max(Self.minWidth, image.width + Self.pad * 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail, Self.showsImage(content, peek) { thumbnail(detail) }
            VStack(alignment: .leading, spacing: 2) {
                // 间距按有没有会话给：没有会话时那些附加元素不存在，仍会占掉一份间距，
                // 而名字那一档的宽度是照标题量出来的，少几个点就要截断（实测「Claude」
                // 变成「Cla…」）。间距是取值，不是分支，identity 不受影响。
                HStack(alignment: .firstTextBaseline, spacing: content == nil ? 0 : 7) {
                    if let content {
                        Image(systemName: Self.symbol(content))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Self.tint(content))
                            .frame(width: Self.symbolWidth)
                    }
                    // 各档共用这一个 Text。换成两个，它们之间就只剩淡入淡出可做了。
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(pill ? 1 : 2)
                        .truncationMode(.tail)
                        // 名字那一档整张卡不定宽，长标题就在这里截住；别的档卡片已经
                        // 定宽了，这里放开让它填满。是取值不是分支，identity 不受影响。
                        .frame(maxWidth: pill ? Self.maxWidth - Self.textPad * 2 : .infinity,
                               alignment: .leading)
                if let session = content?.session {
                        Spacer(minLength: 8)
                        // 停了就把表停在收尾那一刻：任务已经结束，那个数字再往上走
                        // 说的就不是它跑了多久了。
                        LiveElapsed(start: session.turnStarted,
                                    end: session.isUnread ? session.updated : nil,
                                    agent: session.agent)
                    }
                }
                .frame(height: Self.headHeight(detail: detail, content: content),
                       alignment: pill ? .center : .topLeading)
                if let detail, content == nil, Self.showsAppName(title, detail) {
                    Text(detail.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(height: Self.appNameHeight, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.textPad)
            .padding(.vertical, pill ? 0 : Self.textInset)
            switch content {
            case .session(let session): sessionBlock(session)
            case .media(let playing): mediaBlock(playing)
            case nil: EmptyView()
            }
        }
        // 宽度是设计约束，写在这里；高度由上面那棵树自己长出来。见 `width`。
        // 名字那一档 `width` 是 nil，跟着文字走，上限由标题那一行自己截（见 body 里的
        // `titleCap`）——**不能在这里加 `.frame(maxWidth:)`**：那样会把定宽 300 的会话卡
        // 夹到 252，而且给了确定提议之后，里面 `maxWidth: .infinity` 的文字列会一路撑满，
        // 每张卡都变成一样宽。
        .frame(width: width, alignment: .leading)
        // 播放时整张卡取一层封面的颜色。它同时回答三件事：哪一格在发声、换没换歌、
        // 以及这首歌长什么样——一个元素干三件事，比三个元素各干一件好。
        .background(alignment: .bottom) {
            if let tint = content?.media?.tint {
                LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.04)],
                               startPoint: .bottom, endPoint: .top)
                    .animation(.easeInOut(duration: 0.45), value: tint)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 标题行左边那个图标。
    private static func symbol(_ content: CellStatus) -> String {
        switch content {
        case .session(let session): return session.symbol
        // 在放就是音符，停着就是暂停。格子那边靠均衡器动不动来分，
        // 面板这边有按钮，图标只需要说清此刻是哪一种。
        case .media(let playing): return playing.playing ? "music.note" : "pause.fill"
        }
    }

    private static func tint(_ content: CellStatus) -> Color {
        switch content {
        case .session(let session): return session.tint
        case .media(let playing): return playing.tint ?? .secondary
        }
    }

    @ViewBuilder
    private func sessionBlock(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let prompt = session.prompt {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(Self.promptLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Self.rowGap)
            }
            if let ask = session.ask {
                askBlock(ask)
            } else if let response = session.response, session.isUnread {
                // 停了就贴结论，不再列经过。那一刻要的是「结果是什么」，
                // 而经过想看的时候还在终端里。
                Text(Self.styled(response))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(Self.responseLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                // 只列得下末尾几条，所以要报出总数——否则读到的是「它一共就走了这几步」
                if session.turnSteps > session.history.count {
                    Text(localized("activity.steps.count", session.turnSteps))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(height: Self.countHeight, alignment: .leading)
                }
                // 旧的在上、当前在下：读起来是一条往下走的时间线，最新的那一行贴着
                // 卡片底边，也就是离条最近的地方。
                ForEach(session.history) { step in
                    row(symbol: step.verb.symbol, verb: step.verb.text, object: step.object,
                        metric: step.metric, tint: .tertiary, current: false)
                }
                let current = session.stateDetail
                row(symbol: session.symbol, verb: session.stateParts.verb,
                    object: current.object, metric: current.metric,
                    tint: session.tint, current: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.textPad)
        .padding(.bottom, Self.textInset)
    }

    /// 等着你批的那一段（实时状态设计 §4.7）。
    ///
    /// 它答的是一个是非题，所以版面只有三样：**要做什么**、**做在什么上**、**批不批**。
    /// 近期动作那几行让位给它——这一刻卡片的用途不是让你读进度，是让你按下去。
    @ViewBuilder
    private func askBlock(_ ask: Session.Ask) -> some View {
        row(symbol: ask.verb.symbol, verb: ask.verb.text, object: ask.object, metric: nil,
            tint: Color.accentColor, current: true)
        if !ask.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ask.lines) { line in
                    HStack(spacing: 5) {
                        Text(line.sign.rawValue)
                            .foregroundStyle(Self.askTint(line.sign))
                            .frame(width: 7, alignment: .leading)
                        // 命令与代码不折行：折了行的 diff 比截断更难读，
                        // 而这一段是拿来扫一眼下判断的，不是拿来通读的
                        Text(line.text)
                            .foregroundStyle(line.sign == .same
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.askTint(line.sign)))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(height: Self.askLineHeight)
                    .background(Self.askTint(line.sign).opacity(line.sign == .same ? 0 : 0.09))
                }
            }
            .padding(.vertical, Self.askBoxPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
            .padding(.top, Self.rowGap / 2)
        }
        // 截短了就得说。一份被悄悄截短的 diff 会让人以为改动就这么点。
        if ask.more > 0 {
            Text(localized("activity.ask.more", ask.more))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(height: Self.countHeight, alignment: .leading)
        }
        // 两个键平分整行。这张卡此刻的用途就是按下去，而缩在右下角的一对小键
        // 既难点，也在说「这不是重点」。
        HStack(spacing: 8) {
            askButton(localized("activity.ask.deny"), prominent: false) {
                onAnswer(ask.id, false)
            }
            askButton(localized("activity.ask.allow"), prominent: true) {
                onAnswer(ask.id, true)
            }
        }
        .frame(height: Self.buttonHeight)
        .padding(.top, Self.rowGap)
    }

    /// 增删两色。同一个色也用在那一行的底色上，浅一档。
    private static func askTint(_ sign: Session.Ask.Line.Sign) -> Color {
        switch sign {
        case .added: return .green
        case .removed: return .red
        case .same: return .secondary
        }
    }

    private func askButton(_ title: String, prominent: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity)
                .frame(height: Self.buttonHeight)
                .background(prominent
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(.quaternary.opacity(0.7)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 播放（实时状态设计 §5）

    private static let artworkSize: CGFloat = 56
    /// 细线加一行时间。刻意不是一根粗条——那是播放器控件的样子，不是一张卡的样子。
    /// 时间移到线的两端之后，这一行不再是「线 + 一行字」两截
    private static let progressHeight: CGFloat = 14
    private static let controlHeight: CGFloat = 32

    /// 这一档全是定高的，因此高度是算出来的而不是量出来的。量文字那条路在这张卡上
    /// 已经错过两次，能不走就不走。
    private static var mediaHeight: CGFloat {
        artworkSize + rowGap + progressHeight + rowGap + controlHeight + textInset
    }

    @ViewBuilder
    private func mediaBlock(_ playing: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                artwork(playing)
                lines(playing)
            }
            .frame(height: Self.artworkSize)
            MediaProgress(playing: playing, tint: playing.tint ?? .accentColor)
                .frame(height: Self.progressHeight)
                .padding(.top, Self.rowGap)
            HStack(spacing: 20) {
                Spacer(minLength: 0)
                mediaButton("backward.fill", size: 13) { onMedia(.previous) }
                // 中间那个大一圈。最常按的就是它，大一号手就不必瞄。
                mediaButton(playing.playing ? "pause.fill" : "play.fill", size: 18) {
                    onMedia(playing.playing ? .pause : .play)
                }
                mediaButton("forward.fill", size: 13) { onMedia(.next) }
                Spacer(minLength: 0)
            }
            .frame(height: Self.controlHeight)
            .padding(.top, Self.rowGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.textPad)
        .padding(.bottom, Self.textInset)
    }

    /// 歌名、歌手、专辑，从重到轻，整栏对着封面居中。
    ///
    /// **每一行按歌的身份换掉，槽位按序号固定。** 先前是三个 `if let` 并排，子视图的数量
    /// 会随歌变（单曲没有专辑行），数量一变结构标识就错位，兄弟视图跟着被拆掉重建——那正是
    /// 「刷新了一下」的来源。用 `ForEach` 按序号定身份之后，行数变化只影响最后那一槽。
    @ViewBuilder
    private func lines(_ playing: NowPlaying) -> some View {
        let texts = [playing.title, playing.artist,
                     // 单曲的专辑名常常就是歌名，歌手的精选集则常常就是歌手名。
                     // 重复的那一行不占位置——它没有第三样东西可说。
                     playing.album.flatMap {
                         $0 == playing.title || $0 == playing.artist ? nil : $0
                     }].compactMap { $0 }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                // 每一槽是一个**稳定的容器**，动画挂在它身上。
                //
                // 动画不能挂在换身份的那个视图上：它自己就是被换掉的东西之一，换的那一刻
                // 它已经不在了，也就没有谁提供过渡所需的那次事务——表现是过渡根本不播。
                ZStack(alignment: .leading) {
                    Text(text)
                        .font(Self.lineFonts[index])
                        .foregroundStyle(Self.lineStyles[index])
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(playing.track)
                        .transition(playing.advance.drift(step: Self.lineStep,
                                                          blur: Self.lineBlur))
                }
                // 封面先动，两行字依次跟上。**同一条曲线、同一个时长、起点错开**——
                // 那不是几件事，是一件事在这一行上传过去。
                .animation(Self.beat.delay(Double(index + 1) * Self.stagger),
                           value: playing.track)
            }
        }
        // 宽度取满：新旧两行同时在场时，容器不会跟着较宽的那行伸缩
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let lineFonts: [Font] = [.system(size: 13, weight: .semibold),
                                            .system(size: 11.5),
                                            .system(size: 10.5)]
    private static let lineStyles: [HierarchicalShapeStyle] = [.primary, .secondary, .tertiary]

    /// 换歌时整行共用的这一条曲线。
    private static let beat = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// 相邻两个元素之间错开多久。
    private static let stagger = 0.045
    /// 方向性偏置。**取值等于封面到文字的间距**：退出的那一行走到头时正好贴着封面，
    /// 而那一刻它的不透明度已经是 0，因此这一栏不必裁剪——模糊碰上硬裁剪会在边界上
    /// 切出一道生硬的线，比让它压过去难看得多。
    private static let lineStep: CGFloat = 10
    /// 糊到读不出字为止，大约是字号的三分之一。
    private static let lineBlur: CGFloat = 4.5
    /// 封面翻过去的角度。
    private static let turn: Double = 42
    /// 封面转开时的模糊。比文字轻——它本来就不是拿来读的，糊重了只剩一团色。
    private static let coverBlur: CGFloat = 3

    /// 封面绕竖轴翻过去，像一面转过来的鼓。
    ///
    /// 下一首时新的那面**从右边转过来**：它进场时右缘朝里（绕 Y 轴正角），转正即停；
    /// 旧的那面左缘朝里转走。上一首整个反过来。方向因此写在旋转的正负号里，
    /// 而不是靠横向位移去说。
    private static func flip(_ playing: NowPlaying) -> AnyTransition {
        let sign: Double = playing.advance == .forward ? 1 : -1
        return .asymmetric(
            insertion: .modifier(active: Flip(progress: 1, angle: turn * sign),
                                 identity: Flip(progress: 0, angle: turn * sign)),
            removal: .modifier(active: Flip(progress: 1, angle: -turn * sign),
                               identity: Flip(progress: 0, angle: -turn * sign)))
    }

    /// 封面翻过去。旋转、模糊、不透明度同样由一个数驱动，与文字那一侧同一个形状。
    ///
    /// **必须实现 `Animatable`。** `.modifier(active:identity:)` 的过渡靠插值修饰器的
    /// `animatableData`；不声明的话它默认是 `EmptyAnimatableData`，角度会在两个状态之间
    /// 瞬间切换——那等于没有翻转，屏幕上什么都看不见。
    private struct Flip: ViewModifier, Animatable {
        var progress: Double
        /// 完全转开时的角度。
        let angle: Double

        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            content
                .rotation3DEffect(.degrees(angle * progress), axis: (x: 0, y: 1, z: 0),
                                  anchor: .center, perspective: 0.7)
                .blur(radius: PreviewCard.coverBlur * progress)
                .opacity(1 - progress)
        }
    }

    private func artwork(_ playing: NowPlaying) -> some View {
        ZStack {
            cover(playing)
                .id(playing.track)
                .transition(Self.flip(playing))
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        // 封面是这一行的领奏：它先动，文字依次跟上
        .animation(Self.beat, value: playing.track)
    }

    private func cover(_ playing: NowPlaying) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let image = playing.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }

    private func mediaButton(_ symbol: String, size: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.primary)
                // 播放与暂停之间是**字形形变**，不是两张图硬切
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 18, height: Self.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 时间线上的一行：图标、动作名、对象、量化结果。
    ///
    /// 对象走等宽字：文件名与命令是代码，正文字体里的 `l` 和 `1` 分不开，
    /// 而且换一种字本身就把它和左边那一栏拉开层次，不必再画一条竖线。
    private func row(symbol: String, verb: String, object: String?, metric: String?,
                     tint: some ShapeStyle, current: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9.5))
                .foregroundStyle(tint)
                .frame(width: Self.symbolWidth)
            Text(verb)
                .font(.system(size: 11, weight: current ? .medium : .regular))
                .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(width: Self.verbWidth, alignment: .leading)
            Text(object ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // 量化结果右对齐成一栏：几行动作的数值竖直对齐，一眼比得出哪一步改得大
            Text(metric ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: Self.rowHeight)
    }

    /// 回复里的 Markdown。
    ///
    /// 只认行内语法：`.full` 认得块结构，却把字符流里的换行全吃掉，直接渲染会连成一行
    /// （实测）。行内这一档保留换行，粗体、斜体、行内代码都在。行内代码要自己换字体——
    /// 它是这段文字里唯一需要与正文区分的东西。
    private static func styled(_ markdown: String) -> AttributedString {
        guard var text = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(markdown) }
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = .system(size: 11, design: .monospaced)
        }
        return text
    }

    private func thumbnail(_ detail: Detail) -> some View {
        let size = Self.imageSize(
            detail.image,
            box: Self.imageBox(peek,
                               showsAppName: content == nil && Self.showsAppName(title, detail),
                               content: content))
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

/// 会话跑了多久，每秒走一格。
///
/// 只在面板存在的那几秒里跑：条上不添第二样会动的东西——条的动效只有格子边缘那一处，
/// 那是身份层唯一允许的偏离。数字走等宽：不然每跳一秒，右边那一栏就横着挪一下。
/// 播放进度：一根细线，两端各一个时间，已播的那一端一点光。
///
/// **位置是本地推算的，不去轮询。** 桥送来的是「某一刻的位置 + 速率 + 那一刻是什么时候」，
/// 剩下的自己往前推就行；真正要收推送的只有换歌、暂停这些实际发生的变化。
///
/// **线按帧走，不按秒走。** 先前每秒重算一次宽度，三分钟的歌铺在五百多点上，一秒就是
/// 将近 3pt——那不是在走，是在跨步，而末端有了一点光之后，跨步会变成光在瞬移。位置本来
/// 就是从时钟推出来的，按帧取样它自己就连续，因此也不需要给宽度挂线性动画：挂了的话，
/// 跳转与暂停会「滑」到新位置，而它们应该直接落位。两端的时间仍按秒重算——它们一秒才
/// 变一次，跟着帧走只是白排一遍版。
///
/// **轨道不做凹陷。** 深色卡上未播那段必须比卡片更亮才看得见，凹陷只会得到一个黑洞；
/// `.quaternary` 本来就随外观翻转。造出层次的是末端那点光，不是凹槽。
private struct MediaProgress: View {
    @Environment(\.colorScheme) private var scheme
    let playing: NowPlaying
    /// 取自封面。已播那段是这张卡上唯一会动的东西，也就该是承接封面颜色的那一处。
    let tint: Color

    private static let track: CGFloat = 5

    var body: some View {
        HStack(spacing: 8) {
            time { Self.clock(playing.position(at: $0)) }
            bar
            if let total = playing.duration, total > 0 {
                time { "−" + Self.clock(total - playing.position(at: $0)) }
            }
        }
    }

    private func time(_ text: @escaping (Date) -> String) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(context.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var bar: some View {
        TimelineView(.animation) { context in
            let total = playing.duration ?? 0
            let fraction = total > 0
                ? min(1, max(0, playing.position(at: context.date) / total)) : 0
            GeometryReader { geometry in
                let filled = geometry.size.width * fraction
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    played(width: filled)
                }
                .frame(width: geometry.size.width, height: Self.track)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }

    /// 已播那段：从暗渐亮，末端最亮，然后是一个利落的圆头。
    ///
    /// **亮是渐变本身给的，不额外画一团光。** 光晕那条路试了三次，三次都难看，而且失败的
    /// 方式一次比一次清楚：实心圆盖不住核、半径小峰值高的落差边缘仍有形状、定长的白亮边在
    /// 进度低时比填充还长。真正的问题是方向反了——参考里那根线并没有光晕，末端之所以像在
    /// 发光，是因为**填充自己从暗走到亮**，收口反而是干净的。
    ///
    /// 深色下走到白，浅色下不能：白色填充落在浅色卡上就没了，那一支的「亮」是颜色本身
    /// 从淡走到实。
    private func played(width: CGFloat) -> some View {
        let stops: [Gradient.Stop] = scheme == .dark
            ? [.init(color: tint.opacity(0.5), location: 0),
               .init(color: tint, location: 0.55),
               .init(color: .white, location: 1)]
            : [.init(color: tint.opacity(0.45), location: 0),
               .init(color: tint, location: 1)]
        return Capsule()
            .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            .frame(width: width)
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

private struct LiveElapsed: View {
    let start: Date
    /// 停在这一刻。nil = 还在跑，跟着走。
    let end: Date?
    let agent: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text([agent, Self.text(start, end ?? context.date)].compactMap { $0 }
                .joined(separator: " · "))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// 一小时以内报分秒，超过就报时分——秒在那个尺度上已经没有信息了。
    private static func text(_ start: Date, _ now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%d:%02d", minutes, seconds)
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
    /// 卡片把自己登记进这本册子，供右键判定。位置到用的时候现问，见 `ZoneRegistry`。
    let zones: ZoneRegistry
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
        .zone("panel.w\(cell.id)", in: zones)
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
