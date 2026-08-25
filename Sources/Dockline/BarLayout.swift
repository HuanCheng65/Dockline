import AppKit
import DocklineCore

/// 盒模型、顶层项模型与宽度降级阶梯。计划书 §3.1。
///
/// 与视图分离是有原因的：降级级别必须在渲染之前定下来，而且必须是纯函数——
/// 「悬停哪一组」不能参与级别判定，否则用户每移一次鼠标 bar 就换一次形态。

/// 图标 38 与图标 28 是设计定稿的两个端点（画布 `design/Unified.dc.html`），
/// 中间态线性插值。「整体缩放至 28pt 下限」在系统 Dock 上是连续的，这里照做。
struct BarMetrics {
    /// 图标尺寸跟随系统 Dock 的 tilesize。
    ///
    /// 写死尺寸的结果是实机比例失调：条比系统 Dock 高、图标却比它小。
    /// 跟着 tilesize 走，用户把 Dock 调大调小，Dockline 自然是协调的。
    /// 启动时读一次——bar 的高度不该在运行期变（§3.1）。
    /// 可调。缺省跟随系统程序坞的 tilesize，用户拖动分隔线或在设置里改后写入配置。
    static var iconFull: CGFloat = systemDockTileSize
    static let minIcon: CGFloat = 36
    static let maxIcon: CGFloat = 72

    static var systemDockTileSize: CGFloat {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let value = CFPreferencesCopyAppValue("tilesize" as CFString,
                                              "com.apple.dock" as CFString) as? NSNumber
        let size = value.map { CGFloat($0.doubleValue) } ?? 52
        return min(max(size, minIcon), maxIcon)
    }

    /// 缩放下限。系统 Dock 的比例：容器高 = 图标 + 20。
    static var iconFloor: CGFloat { (iconFull * 0.72).rounded() }
    /// bar 净高恒定。任何状态变化都不得改变它（§3.1）。
    static var barHeight: CGFloat { iconFull + 20 }
    static var barRadius: CGFloat { (barHeight * 0.34).rounded() }

    static let barPaddingH: CGFloat = 7
    /// 格子之间的呼吸。实测系统程序坞：tilesize 57 时 tile 宽 61、相邻缝 0，
    /// 即图标之外只留 4pt——标准 macOS 图标网格里方形只占画布约八成，
    /// 图标自带的透明边距就是它的内边距，不必在外面再加一层。
    /// 只在 tilesize 57 上量过，因此取常数，不按比例外推。
    static let cellGap: CGFloat = 4
    /// 底色在格子内向内缩这么多。缝由内缩产生，不由布局产生——
    /// 让布局为底色留缝，缝就是全时段的；而底色只在前台 / 悬停这类瞬时状态出现。
    static let backingInset: CGFloat = 2
    /// 运行指示点的直径。它落在盒子下方本来就空着的那条带里，不额外占行。
    static let dotSize: CGFloat = 4
    /// 簇的收拢态：封面满尺寸，后面每层向右偏移露出一条边。露出比例相对图标宽度。
    /// 图标自带约一成的透明边距，会先吃掉大半，所以这个值要比「看起来该露多少」更大
    static let deckReveal: CGFloat = 0.30
    /// 连封面一共露几层。再多就叠成一团糊，超出的数量交给角标。
    static let deckLimit = 3
    /// 标题：两行折行，小字号靠 medium 字重保可读性
    static let labelFontSize: CGFloat = 11.5
    static let labelLines = 2
    static let labelMinWidth: CGFloat = 48
    static let labelMaxWidth: CGFloat = 88
    /// 标题宽度的迟滞阈值。标题一变就调宽会让整条 bar 横向抖动。
    static let labelWidthStep: CGFloat = 6
    static let badgeMinWidth: CGFloat = 15
    static let badgeFontSize: CGFloat = 10
    /// 分隔线：1pt 宽，左右各 7pt 外边距
    static let separatorMargin: CGFloat = 7
    static var separatorHeight: CGFloat { (barHeight * 0.56).rounded() }
    /// 玻璃条离屏幕底边的距离。实测系统程序坞容器为 5pt。
    static let bottomGap: CGFloat = 5
    /// bar 在屏幕底部占掉的高度（含上下留白）。铺满时窗口底边抬到这条线之上。
    static var reservedBottom: CGFloat { bottomGap * 2 + barHeight }
    /// 放格子出溢出区需要多出来的余量。省了它，窗口数在临界点上下抖时条会反复横跳。
    static let overflowSlack: CGFloat = 0.06
    /// 降级触发阈值：内容宽度占屏幕可见宽度的比例。系统程序坞是一路撑到屏幕两边
    /// 只留一点余量才开始缩的，这里与之对齐，留出的余量约等于条离屏幕底边的距离。
    static let maxContentRatio: CGFloat = 0.96

    let icon: CGFloat
    /// 标题的宽度上限。降级第一级压的就是它——从 `labelMaxWidth` 压到 `labelMinWidth`。
    /// 只在这里和视图里以 `min(标题宽, 上限)` 生效，不进 `LabelWidths`：
    /// 那个缓存按文本键控，掺进上限会污染它的迟滞。
    var labelCap: CGFloat = BarMetrics.labelMaxWidth

    /// 标题实际占的宽度
    func label(_ width: CGFloat) -> CGFloat { min(width, labelCap) }

    /// t = 1 是满尺寸端，t = 0 是缩放下限端
    private var t: CGFloat {
        (icon - Self.iconFloor) / max(Self.iconFull - Self.iconFloor, 1)
    }
    private func lerp(_ full: CGFloat, _ floor: CGFloat) -> CGFloat { floor + (full - floor) * t }

    /// 统一盒模型：一格 = 图标 + 呼吸，没有别的。条上的项彼此紧邻，也没有项间距——
    /// 图标之间的可见间距因此与系统程序坞一致，而不是三层留白叠出来的 16pt。
    var cellBox: CGFloat { icon + Self.cellGap }
    /// 图标外的半边呼吸。所有项共用它作内边距，图标因此落在同一条基线上。
    var cellInset: CGFloat { Self.cellGap / 2 }
    /// 指示点从图标下沿往下落的距离：越过格内边距，落进盒子与条底之间那条带
    var dotDrop: CGFloat { cellInset + 4 }
    var cellRadius: CGFloat { (cellBox - Self.backingInset * 2) * 0.30 }
    var labelGap: CGFloat { lerp(4, 3) }
    /// 标签到下一格必须明显宽于标签到它自己的图标。没有底盒兜着的时候，
    /// 标签归谁只剩邻近性可依据，两侧一样宽就读不出来了。
    var labelTrailing: CGFloat { lerp(10, 8) }
}

/// 底色三档（计划书 §3.1）。底色回答的是「此刻与你相关的是哪一格」，因此是瞬时的；
/// 常驻的「这里有窗口可以召回」交给图标下方的指示点。
///
/// 分层的根据是密度：底色是盒子，盒子要内边距、相邻两块还要留缝，一格因此至少多占 10pt；
/// 而条上几乎每一格都是窗口，等于全时段为一个人人都有、谁也不区分的记号付费。
/// 点不占横向空间，落在盒子下方的留白带里，密度成本为零。
enum Backing {
    case none     // 静置
    case linked   // 指针停在同 App 的另一个窗口上——被拖散的兄弟靠它可见
    case light    // 悬停
    case bright   // 当前前台窗口
    case focused  // 键盘切换选中——松开修饰键就去那里
}

// MARK: - 顶层项
//
// 排布的单位是窗口（见 `BarElement`），条上的项也就一格一个窗口。
//
// 项的身份必须稳：早先「一段相邻同 App 窗口」是一个项，id 取自段里第一个窗口，
// 段的成员一变 id 就变，SwiftUI 会把整段拆掉重建——看起来就是「item 刷新了一下」。
// 一格一个窗口，id 就是窗口号，从生到死不变。

/// 条上的一格。
struct BarWindow: Identifiable {
    let window: IndexedWindow
    /// 标题区的文字。nil = 该 App 只有这一个窗口，没有兄弟要区分，也就不显示标题。
    /// 内容是剥掉同 App 组内共同首尾段之后的标题——见 `distinctiveLabels`。
    let label: String?
    /// 标题区的宽度。视图与宽度计算读同一个值，两边因此不可能算岔。
    let labelWidth: CGFloat
    let key: AppKey
    let appName: String
    let pid: pid_t
    let bundleID: String?
    /// App 级的东西（未读角标、活动状态）挂在该 App 在条上的第一格，不逐格重复
    let leadsApp: Bool
    /// 收进这一格的原生标签页（含它自己）。空 = 没有收，这一格就是一个普通窗口。
    var tabs: [BarWindow] = []

    var id: CGWindowID { window.id }

    /// 圆点是条上唯一一处「点了会打开」与「点了会聚焦」的歧义消除记号，只用在这里：
    /// 单窗口 App 的格子除了图标什么都没有，与未打开的 App 外形完全一样。
    /// 有标题的格子本身就与启动器区分得开，不再重复标记。
    var showsDot: Bool { label == nil }

    /// 在条上的身份。见 `BarItem.id` 的说明。
    var identity: String {
        guard leadsApp, let bundleID else { return "w\(window.id)" }
        return "app.\(bundleID)"
    }
}

/// 捏合成的簇。在条上永远是折叠的一格：封面 + 堆叠 + 色线，默认没有标题。
///
/// 标题默认不显示是因为簇是用户手上的压缩工具：带标题的簇格与带标题的窗口格一样宽，
/// 五个窗口聚成一个也省不出多少横向空间。辨识靠封面、堆叠边缘和色线三个信号就够——
/// 尤其色线是用户自己挑的颜色，认起来比读字快。起过名字的人可以在右键菜单里打开。
struct BarCluster {
    let id: Int
    /// 成员，最近活跃的排在最前——第一个就是封面
    let windows: [BarWindow]
    let name: String?
    let color: ClusterColor
    let showsName: Bool
    let labelWidth: CGFloat

    /// 标题第一行。没起名字就退回封面窗口的标题——它同样是系统自有数据，
    /// 比一个「编组 1」之类的占位名有用。
    var heading: String { name ?? windows[0].window.title }
    /// 第二行。簇名与窗口数都是系统自有字段，因此这里可以结构化排版，
    /// 不像普通窗口的标题那样只能直排。
    var subheading: String { "\(windows.count) 个窗口" }
    /// 露出几层
    var layers: Int { min(windows.count, BarMetrics.deckLimit) }
    /// 叠不下的成员数交给角标
    var overflow: Int { windows.count - layers }
}

/// 固定了、或本会话开过窗口，但此刻一个窗口都没有的 App。计划书 §3「固定 App 是槽位，不是图标」：
/// 同一个位置，没窗口时是启动图标，开出窗口后原地被它的窗口替换。
/// 指示点的三档（计划书 §3.1 / §6 M5）。
///
/// 它回答的是「这里有没有窗口可以召回」。多显示器下这个问题有三个答案，而不是两个——
/// 少了中间那一档，一个「窗口都在别的屏」的固定 App 就长着和「压根没开」一模一样的脸，
/// 而点下去的结果完全不同。**三档各自预告了点这一格会发生什么**，记号先说，用户才点。
enum WindowMark {
    /// 一个窗口都没有 —— 点它是启动
    case none
    /// 有窗口，但都在别的屏 —— 点它是把它拿到这块屏来
    case elsewhere
    /// 这块屏上有 —— 点它是召回
    case here
}

struct DormantApp {
    let bundleID: String
    let name: String
    let url: URL?        // nil = App 已被删除，图标解析不出来
    let pid: pid_t?      // 非 nil = 在运行，只是一个窗口都没有
}

/// 可以拖动的东西。
enum DragUnit: Hashable {
    case window(CGWindowID)
    case app(AppKey)
    case cluster(Int)

    /// 与视图里那一格的底色键对齐
    var backingID: String {
        switch self {
        case .window(let id): return "w\(id)"
        case .app(let key): return "app.\(key.bundleID ?? "?")"
        case .cluster(let id): return "cluster.\(id)"
        }
    }
}

enum BarItem: Identifiable {
    case launcher(URL)
    /// 权限未就绪时占据窗口区的说明文字
    case notice(String)
    case separator(String)
    case window(BarWindow)
    case dormant(DormantApp)
    case cluster(BarCluster)
    /// ⑤ 溢出入口。它是条自己的控件，不是一个系统偷偷建的簇——所以既没有堆叠也没有色线。
    case overflow([BarWindow])
    case folder(URL)
    case trash

    var id: String {
        switch self {
        case .launcher: return "launcher"
        case .notice: return "notice"
        case .separator(let side): return "sep.\(side)"
        // 该 App 在条上的第一格沿用 App 的身份：没启动时它是启动图标、启动后是窗口格，
        // 前后是同一个位置上的同一件事。id 一变，SwiftUI 就会拆掉重建——
        // 看起来就是「App 一启动，那一格刷新了一下」。
        case .window(let cell): return cell.identity
        case .dormant(let app): return "app.\(app.bundleID)"
        case .cluster(let cluster): return "cluster.\(cluster.id)"
        case .overflow: return "overflow"
        case .folder(let url): return "folder.\(url.path)"
        case .trash: return "trash"
        }
    }

    var dragUnit: DragUnit? {
        switch self {
        case .window(let cell): return .window(cell.id)
        case .dormant(let app): return .app(.bundle(app.bundleID))
        case .cluster(let cluster): return .cluster(cluster.id)
        default: return nil
        }
    }
}

// MARK: - 组装

/// 让顺序与簇跟上现实。**全局做一次**，在任何一条 bar 出格之前。
///
/// 顺序与簇都是全局对象：`WindowOrder.reconcile` 会剪掉不在入参里的窗口，
/// 每条 bar 各拿本屏那部分窗口来对齐的话，后一条会把前一条的窗口从共享的顺序里剪掉。
/// 位置的归属从此只在这一处决定。
///
/// - Parameter retained: 本会话开过窗口、此刻一个窗口都没有、但进程还活着的 App。
///   计划书 §2 只把常驻空间分给「用户会想找回来的东西」——微信 / QQ 关掉窗口后
///   进程还在，用户确实想回得去，所以留位；而 Stats / Clash Verge 这类从来没开过
///   真窗口的菜单栏 App 一次都不会进来。判据是「历史上有过窗口」，不是「进程在运行」。
func alignBarOrder(windows: [IndexedWindow], pins: PinStore, retained: Set<AppKey>,
                   clusters: ClusterStore, order: WindowOrder) {
    clusters.prune(present: Set(windows.map(\.id)))
    let withWindows = Set(windows.map(\.appKey))
    let placeholders = Set(pins.pinnedApps.map(AppKey.bundle)).union(retained)
        .subtracting(withWindows)
    order.reconcile(windows: windows, placeholders: placeholders, rank: pins.rank)
    pins.setAppOrder(order.appOrder)
}

/// 计划书 §3 结构顺序：启动台 │ 窗口区 │ 固定文件夹 · 垃圾桶
///
/// 一条 bar 只画归本屏的窗口（计划书 §6 M5「对象归属」）。入参仍是**全部**窗口：
/// 标题歧义要按 App 全局算，簇也可能有成员在别的屏上。
/// - Parameter onThisDisplay: 归本屏的窗口。
/// - Parameter dormantHere: 一个此刻没有窗口的 App，它的占位槽该不该出现在本屏。
func makeBarItems(windows: [IndexedWindow], onThisDisplay: Set<CGWindowID>,
                  dormantHere: (AppKey) -> Bool, pins: PinStore, notice: String?,
                  clusters: ClusterStore, order: WindowOrder,
                  labels: LabelWidths, recency: (CGWindowID) -> Int) -> [BarItem] {
    // 三、标题只在同 App 有兄弟时出现。按 App 全局算——同 App 的两个窗口
    // 即使被拖散了，也还是要能区分。
    let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let hasSiblings = Set(Dictionary(grouping: windows, by: \.appKey)
        .filter { $0.value.count > 1 }.flatMap { $0.value.map(\.id) })

    // 一个 App 在条上的「第一格」：未读角标与活动状态挂在它上面，它也沿用 App 的身份。
    // 只在条上直接露面的窗口里选——簇里的窗口平时看不见，挂上去等于没挂。
    var leaders = Set<AppKey>()
    func cell(_ window: IndexedWindow, leads: Bool) -> BarWindow {
        let label = hasSiblings.contains(window.id) ? window.title : nil
        return BarWindow(window: window, label: label,
                         labelWidth: label.map { labels.width(of: "w\(window.id)", $0) } ?? 0,
                         key: window.appKey,
                         appName: window.appName, pid: window.pid, bundleID: window.bundleID,
                         leadsApp: leads)
    }

    // 四、走一遍顺序，一格一个窗口。顺序是全局的，本屏只挑自己那些。
    var slots: [BarItem] = []
    var emitted = Set<Int>()
    /// 已经在本屏画过的窗口，供标题缓存做剪枝——簇的成员可能来自别的屏。
    var shown = Set<CGWindowID>()
    /// 本屏已经补过槽位的固定 App，别补第二次。
    var slotted = Set<AppKey>()
    let localApps = Set(windows.filter { onThisDisplay.contains($0.id) }.map(\.appKey))

    func note(_ window: IndexedWindow, leads: Bool) -> BarWindow {
        shown.insert(window.id)
        return cell(window, leads: leads)
    }

    for element in order.elements {
        switch element {
        case .app(let key):
            guard dormantHere(key), let bundleID = key.bundleID else { continue }
            slots.append(.dormant(dormant(bundleID: bundleID)))

        case .window(let wid):
            guard let window = byID[wid] else { continue }
            guard onThisDisplay.contains(wid) else {
                // 这个窗口在别的屏上。它的 App 若被固定、本屏又没有它的窗口，本屏就该在
                // 这个位置留一个槽位——固定 App 每块屏都有（计划书 §6 M5）。
                guard let bundleID = window.bundleID, pins.isPinned(bundleID),
                      !localApps.contains(window.appKey),
                      slotted.insert(window.appKey).inserted else { continue }
                slots.append(.dormant(dormant(bundleID: bundleID)))
                continue
            }
            guard let id = clusters.clusterID(of: wid) else {
                slots.append(.window(note(window, leads: leaders.insert(window.appKey).inserted)))
                continue
            }
            guard emitted.insert(id).inserted else { continue }
            guard let cluster = clusters.cluster(id) else { continue }
            // 封面是最近活跃的那一个：折叠态只露一张脸，露最近用过的那张才有用。
            // 跨屏的簇在每块有成员的屏上各投影一份，封面与展开次序都优先本屏成员
            // （计划书 §6 M5「簇跨屏投影」）——身份仍是同一个簇。
            let members = cluster.windows.compactMap { byID[$0] }
                .sorted {
                    let (a, b) = (onThisDisplay.contains($0.id), onThisDisplay.contains($1.id))
                    return a == b ? recency($0.id) > recency($1.id) : a
                }
            guard members.count > 1 else { continue }
            let cells = members.map { note($0, leads: false) }
            let heading = cluster.name ?? cells[0].window.title
            slots.append(.cluster(BarCluster(
                id: id, windows: cells, name: cluster.name, color: cluster.color,
                showsName: cluster.showsName,
                labelWidth: cluster.showsName
                    ? labels.width(of: "cluster.\(id)", heading, "\(cells.count) 个窗口")
                    : 0)))
        }
    }

    labels.prune(present: Set(shown.map { "w\($0)" })
        .union(emitted.map { "cluster.\($0)" }))

    var items: [BarItem] = [.launcher(pins.launcher), .separator("left")]
    if let notice { items.append(.notice(notice)) }
    items += slots
    items.append(.separator("right"))
    items += pins.folders.map(BarItem.folder)
    items.append(.trash)
    return items
}

private func dormant(bundleID: String) -> DormantApp {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    let url = running?.bundleURL
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    return DormantApp(bundleID: bundleID,
                      name: running?.localizedName
                          ?? url.map { FileManager.default.displayName(atPath: $0.path) }
                          ?? bundleID,
                      url: url,
                      pid: running?.processIdentifier)
}

/// 收拢态那一摞的宽度：封面满尺寸，后面每层露出一条边
func deckWidth(_ layers: Int, icon: CGFloat) -> CGFloat {
    icon * (1 + BarMetrics.deckReveal * CGFloat(max(layers, 1) - 1))
}

// MARK: - 文字宽度

private let badgeFont = NSFont.systemFont(ofSize: BarMetrics.badgeFontSize, weight: .semibold)
private let labelFont = NSFont.systemFont(ofSize: BarMetrics.labelFontSize, weight: .medium)

func badgeWidth(_ count: Int) -> CGFloat {
    let text = "\(count)" as NSString
    return max(BarMetrics.badgeMinWidth, ceil(text.size(withAttributes: [.font: badgeFont]).width) + 8)
}

// MARK: - 标题宽度
//
// 标题两行折行，排不下末尾截断。文本来自 distinctiveLabels——剥掉同 App 组内共同的
// 首尾段，剩下的才是这个窗口独有的东西；剥不动就退回完整标题。
//
// 宽度不能在视图里定：`frame(maxWidth:)` 在外层 fixedSize 下的理想宽就是上限值，
// 短标题也会占满。这里一次算准，视图与降级阶梯读同一个值。

/// 每个窗口的标题宽度。带迟滞：标题一变就调宽，整条 bar 会横向抖动。
final class LabelWidths {
    private var resolved: [String: (text: String, width: CGFloat)] = [:]

    /// 多行时取最宽的一行。
    func width(of key: String, _ texts: String...) -> CGFloat {
        let joined = texts.joined(separator: "\u{0}")
        let fresh = { texts.map(Self.measure).max() ?? BarMetrics.labelMinWidth }
        guard let cached = resolved[key] else {
            let width = fresh()
            resolved[key] = (joined, width)
            return width
        }
        guard cached.text != joined else { return cached.width }
        let width = fresh()
        // 微小变化不调宽
        guard abs(width - cached.width) > BarMetrics.labelWidthStep else {
            resolved[key] = (joined, cached.width)
            return cached.width
        }
        resolved[key] = (joined, width)
        return width
    }

    func prune(present: Set<String>) {
        resolved = resolved.filter { present.contains($0.key) }
    }

    /// 排成一行要多宽，夹在 min/max 之间。
    ///
    /// 不去找「能装下两行的最窄宽度」：那个宽度会把「zoom1.png」这样的长词从中间劈开
    /// （实测排成「zoom1.pn / g」）。折行让排版自己决定，宽度只负责伸缩与上限。
    /// NSFont 量出的宽比 SwiftUI 实际排版需要的窄几个点，恰好一行的标题可能折成两行——
    /// 两行本来就是允许的形态，无害。
    private static func measure(_ text: String) -> CGFloat {
        let single = ceil((text as NSString).size(withAttributes: [.font: labelFont]).width)
        return min(max(single, BarMetrics.labelMinWidth), BarMetrics.labelMaxWidth)
    }
}

// MARK: - 降级阶梯

/// 计划书 §3.1。放不下时按信息的重要性依次退让，每一级都压到自己的底线，才进下一级：
/// ① 满尺寸 → ② 标签组收成一格 → ③ 压标题 → ④ 整体缩放 → ⑤ 溢出收纳。
///
/// 顺序的依据是边际代价：标签页有窗口自带的标签栏兜底，收它损失最小而单位收益最大；
/// 标题是第二层级信息，悬停有完整标题与缩略图兜底；图标缩掉三成仍可辨识；
/// 把格子收进溢出区代价最大，因为它从条上消失了。
///
/// 早先还有一级「把相邻的同 App 窗口自动收起成一格」，已删除：它凭空造出一个
/// 用户没有创建过的聚合形态，与「聚簇是唯一的聚合形态、且只能由用户亲手创建」冲突。
/// 末级早先是横向滚动，也已删除：滚动把「一眼看全」这个前提废掉了，而溢出区至少
/// 明确告诉用户「还有几个，在这里」。
struct BarLayout {
    let items: [BarItem]
    let metrics: BarMetrics
    /// ⑤ 收进溢出区的格子。它们不在 `items` 里，只在溢出面板里露面。
    let overflow: [BarWindow]
    /// ② 原生标签页是否收成了一格
    let foldsTabs: Bool
    /// 玻璃条总宽（已含左右内边距）。只用于动画触发，实际宽度由 SwiftUI 自己量。
    let barWidth: CGFloat

    /// 「布局变了没有」的判据。只盯 id 盯不住标题变宽、簇多一层、整体缩放这些——
    /// 而计划书 §3.1 要求任何元素的插入 / 移除 / 伸缩都是位移过渡，不是瞬间重排。
    var signature: String {
        items.map { item in
            switch item {
            case .window(let cell): return "\(item.id):\(cell.labelWidth)"
            case .cluster(let cluster):
                return "\(item.id):\(cluster.layers):\(cluster.labelWidth)"
            default: return item.id
            }
        }.joined(separator: "|")
            + "@\(metrics.icon)/\(metrics.labelCap)+\(overflow.count)"
            + (foldsTabs ? "T" : "")
    }
}

private func itemWidth(_ item: BarItem, metrics: BarMetrics) -> CGFloat {
    switch item {
    case .separator:
        return 1 + BarMetrics.separatorMargin * 2
    case .notice(let text):
        return ceil((text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
            + metrics.cellInset * 2
    // 簇按收拢态算，正好一个格子宽——扇面是浮层，不占条上的宽度
    case .launcher, .folder, .trash, .dormant:
        return metrics.cellBox
    case .cluster(let cluster):
        // 面板是浮层，不占条上的宽度
        let deck = metrics.cellInset * 2 + deckWidth(cluster.layers, icon: metrics.icon)
        guard cluster.showsName else { return deck }
        return deck + metrics.labelGap + metrics.label(cluster.labelWidth) + metrics.labelTrailing
    case .window(let cell):
        guard cell.label != nil else { return metrics.cellBox }
        return metrics.cellBox + metrics.labelGap + metrics.label(cell.labelWidth)
            + metrics.labelTrailing
    case .overflow:
        return metrics.cellBox
    }
}

private func contentWidth(_ items: [BarItem], metrics: BarMetrics) -> CGFloat {
    items.reduce(0) { $0 + itemWidth($1, metrics: metrics) }
}

/// - Parameter availableWidth: 屏幕可见宽度
/// - Parameter overflowing: 上一帧收进溢出区的格子数。用来做迟滞——格子进出溢出区是
///   唯一一个不连续的动作，窗口数在临界点上下抖时，没有迟滞就会来回横跳。
/// - Parameter recency: 窗口上一次被激活的时刻，越大越近。决定谁被收进溢出区。
func makeLayout(items expanded: [BarItem], availableWidth: CGFloat, overflowing: Int,
                recency: @escaping (CGWindowID) -> Int,
                alwaysFoldsTabs: Bool, wasFolded: Bool) -> BarLayout {
    let limit = availableWidth * BarMetrics.maxContentRatio
    let chrome = BarMetrics.barPaddingH * 2
    func fits(_ items: [BarItem], _ metrics: BarMetrics) -> CGFloat {
        contentWidth(items, metrics: metrics) + chrome
    }

    // ② 标签页收拢。放在最前面：一个五标签的窗口收回四格，单位收益最大，而信息损失最小
    //   ——标签栏永远在窗口顶上，从 Dock 直达某个标签只是便利的冗余。收拢与展开是
    //   离散跳变，同样要迟滞：已经收着的话，得宽出一截才展开。
    let full = BarMetrics(icon: BarMetrics.iconFull)
    let folded = alwaysFoldsTabs
        || fits(expanded, full) > limit * (wasFolded ? (1 - BarMetrics.overflowSlack) : 1)
    let items = folded ? foldTabs(expanded) : expanded

    // 压到底的那一档：标题最窄、图标最小。末级要不要出场、要收几个，都按它判。
    let floored = BarMetrics(icon: BarMetrics.iconFloor, labelCap: BarMetrics.labelMinWidth)
    let cells = windowCount(items)
    var needed = 0
    while needed < cells,
          fits(withOverflow(items, count: needed, recency: recency).items, floored) > limit {
        needed += 1
    }

    // 迟滞：要多收随时收，要放出来得宽出一截才放
    var overflow = needed
    if needed < overflowing {
        let slack = limit * (1 - BarMetrics.overflowSlack)
        overflow = overflowing
        for k in needed..<overflowing
        where fits(withOverflow(items, count: k, recency: recency).items, floored) <= slack {
            overflow = k
            break
        }
    }

    if overflow > 0 {
        let split = withOverflow(items, count: overflow, recency: recency)
        return BarLayout(items: relead(split.items), metrics: floored, overflow: split.taken,
                         foldsTabs: folded, barWidth: fits(split.items, floored))
    }

    // ① 满尺寸
    let width = fits(items, full)
    if width <= limit {
        return BarLayout(items: items, metrics: full, overflow: [], foldsTabs: folded,
                         barWidth: width)
    }

    // ③ 压标题：图标不动，标题上限从 88 压到 48
    var cap = BarMetrics.labelMaxWidth
    while cap > BarMetrics.labelMinWidth {
        cap = max(cap - 2, BarMetrics.labelMinWidth)
        let metrics = BarMetrics(icon: BarMetrics.iconFull, labelCap: cap)
        let capped = fits(items, metrics)
        if capped <= limit {
            return BarLayout(items: items, metrics: metrics, overflow: [], foldsTabs: folded,
                             barWidth: capped)
        }
    }

    // ④ 整体缩放，下限为满尺寸的 0.72。宽度对图标尺寸单调，0.5pt 一档往下试。
    var icon = BarMetrics.iconFull
    while true {
        let metrics = BarMetrics(icon: icon, labelCap: BarMetrics.labelMinWidth)
        let width = fits(items, metrics)
        if width <= limit || icon <= BarMetrics.iconFloor {
            return BarLayout(items: items, metrics: metrics, overflow: [], foldsTabs: folded,
                             barWidth: width)
        }
        icon -= 0.5
    }
}

private func windowCount(_ items: [BarItem]) -> Int {
    items.reduce(0) { if case .window = $1 { return $0 + 1 } else { return $0 } }
}

/// 收 `count` 个进溢出区之后，条上剩下什么。count = 0 时原样返回，条上不出现溢出入口。
private func withOverflow(_ items: [BarItem], count: Int,
                          recency: (CGWindowID) -> Int) -> (items: [BarItem], taken: [BarWindow]) {
    guard count > 0 else { return (items, []) }
    let (kept, taken) = takeaway(items, count: count, recency: recency)
    guard !taken.isEmpty else { return (kept, []) }
    // 入口落在窗口区的末尾，不是整条的末尾——它后面还有固定文件夹和废纸篓
    var shown = kept
    let index = shown.firstIndex { if case .separator("right") = $0 { return true }
                                   else { return false } } ?? shown.endIndex
    shown.insert(.overflow(taken), at: index)
    return (shown, taken)
}

/// ② 把每个原生标签组收成一格。
///
/// 这是唯一适合自动压缩的地方，和「同 App 的相邻窗口自动合并」不是一回事：合并出来的
/// 格子是系统发明的容器，点击语义悬空；而标签组在系统层面本来就住在同一个窗口框架里，
/// 是用户自己建的组，收拢只是退回真实粒度。点击语义因此一字不差——就是那个窗口的开关。
/// 收拢后是一个普通窗口格（标题取当前活跃标签的），加一个数量角标；没有堆叠也没有色线，
/// 它不是簇。悬停浮出面板，取用其中某一个标签。
private func foldTabs(_ items: [BarItem]) -> [BarItem] {
    var members: [CGWindowID: [BarWindow]] = [:]
    for case .window(let cell) in items {
        guard case .tab(let host) = cell.window.source else { continue }
        members[host, default: []].append(cell)
    }
    guard !members.isEmpty else { return items }
    return items.compactMap { item in
        guard case .window(let cell) = item else { return item }
        // 背景标签并进宿主那一格
        if case .tab = cell.window.source { return nil }
        guard let tabs = members[cell.id] else { return item }
        var host = cell
        host.tabs = [cell] + tabs
        return .window(host)
    }
}

/// 收 `count` 个窗口格进溢出区：挑**最久没有被聚焦过**的那几个。
///
/// 条上显示的应该是「你正在干什么」，久没碰过的窗口恰恰是「现在不在干」的那部分，
/// 位置记忆的价值也最低，牺牲它们代价最小。这条规则还自带两个正确的边界行为：
/// 切到条上另一个可见窗口不会引起任何重排（它本来就不在被收的那几个里），
/// 而从别处切到一个已经收起来的窗口，它立刻变成最近使用、自己回到条上，
/// 当前最久没用的那个顶替它进去——一进一出，总宽度不变。
///
/// 收谁只决定「谁出去」，不决定「谁排在哪」：留下的格子位置一律不动。
/// 簇与固定 App 不参与——簇是用户自己的压缩结果，固定 App 是他明确要留在那儿的位置。
private func takeaway(_ items: [BarItem], count: Int,
                      recency: (CGWindowID) -> Int) -> (kept: [BarItem], taken: [BarWindow]) {
    var cells: [(index: Int, cell: BarWindow)] = []
    for (index, item) in items.enumerated() {
        if case .window(let cell) = item { cells.append((index, cell)) }
    }
    let doomed = cells.sorted { recency($0.cell.id) < recency($1.cell.id) }.prefix(count)
    let removed = Set(doomed.map(\.index))
    let taken = doomed.sorted { $0.index < $1.index }.map(\.cell)
    let kept = items.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    return (kept, taken)
}

/// 溢出改变了「哪一格是这个 App 在条上的第一格」。App 级的东西（未读角标、活动状态）
/// 挂在它上面，挂到一个收进面板里的格子上等于没挂，所以要在留下的格子里重选。
private func relead(_ items: [BarItem]) -> [BarItem] {
    var leaders = Set<AppKey>()
    return items.map { item in
        guard case .window(let cell) = item else { return item }
        let leads = leaders.insert(cell.key).inserted
        guard leads != cell.leadsApp else { return item }
        return .window(BarWindow(window: cell.window, label: cell.label,
                                 labelWidth: cell.labelWidth, key: cell.key,
                                 appName: cell.appName, pid: cell.pid,
                                 bundleID: cell.bundleID, leadsApp: leads))
    }
}
