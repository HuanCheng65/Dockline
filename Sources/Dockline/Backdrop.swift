import AppKit
import ScreenCaptureKit
import SwiftUI

/// 玻璃板的明暗（计划书 §3.1）。
///
/// Liquid Glass 自己有这套能力，但只对高度 ≤64pt 的玻璃开——一根 77pt 的条够不着，
/// 绕不过去，只能自己采。整条实测记录与试过的绕法见 `DockGlass`。
///
/// 口径是「文字真正压着的那些像素」：抓**系统合成之后**的画面，不排除任何窗口，
/// 因此拿到的是桌面经 Liquid Glass 渲染出来的那块板，不必自己估算模糊、着色与折射。
/// 采的位置是容器内侧那条纯玻璃（`band`）——那里没有图标也没有文字，所以画面里
/// 有我们自己，也不会把自己的前景色采进来。条与浮层各用一个实例。
///
/// 采样有两条来路。一条挂在事件上：索引变了、前台窗口变了、切了 Space、条从隐藏中
/// 唤出。另一条跟着对账 tick 每 2 秒来一次——这一条是必需的，条底下那个窗口自己换了
/// 内容（切页、播视频、换主题）不触发我们的任何事件，而那正是最常见的情况。
/// 单次约 35ms，异步进行，内部再加 0.5 秒去抖。
final class BackdropSensor {
    /// 只用于日志：条与浮层各有一个实例，读数要能分辨是谁的。
    private let name: String
    var onChange: ((ColorScheme) -> Void)?

    init(name: String) { self.name = name }

    /// 翻转阈值。实测这块玻璃对背景几乎是线性的，压根没把量程压掉多少
    /// （背景 0 / 0.3 / 0.6 / 1.0 → 板 0.07 / 0.30 / 0.52 / 0.78）。
    /// 白字与黑字对比度相等的点按 WCAG 算在 0.46，band 就骑在它两侧；
    /// 留出迟滞是因为只有一个阈值的话，亮度在临界点抖一下，整条 bar 的文字就会来回翻。
    private static let darkBelow = 0.42
    private static let lightAbove = 0.52
    /// 去抖。拖一个窗口经过条底下时，AX 会连着发一串移动事件，这个值决定跟色跟得多紧；
    /// 单次抓图实测 36.9ms（中位数），0.5 秒一次即拖动期间约占一核的 7%，拖完即止。
    private static let minInterval: TimeInterval = 0.5
    /// 上下两条纯玻璃各有多高。条的净高是「图标 + 20」而格子是「图标 + 4」，
    /// 上下各余 8pt；预览卡与簇面板的内边距是 8 / 9pt。再减去避开玻璃边缘的 2pt。
    private static let bandHeight: CGFloat = 6
    /// 上下边缘各让开这么多，避开玻璃自己的高光边。
    private static let edgeInset: CGFloat = 2

    /// 过滤器要定期重建。它是按一次快照建的，用久了抓回来的会是旧画面——
    /// 亮度从此冻住，条上的明暗就再也不动了（实测过，当时的过滤器带排除表；
    /// 换成不排除任何窗口之后是否还会冻，没有复现条件，先照旧重建）。
    private static let filterLifetime = 15

    private var scheme: ColorScheme = .light
    private var filter: SCContentFilter?
    private var filterDisplay: CGDirectDisplayID?
    private var filterAge = 0
    private var sampling = false
    private var lastSample = Date.distantPast
    private var pending: (probe: CGRect, display: CGDirectDisplayID)?
    private var scheduled = false
    /// 上一次报过的失败。同一个原因只报一次，换了原因或恢复后再报——
    /// 失败不设停手开关：拔插显示器会让 ScreenCaptureKit 的显示器列表短暂变空，
    /// 一旦就此停手，插回来也不会自己恢复。
    private var reportedFailure: String?
    /// 上一次记进日志的亮度。阈值是 §9 的待调参项，要靠实机取值来定。
    private var logged: Double?

    /// 要抓的矩形：容器整块，横向内缩一个圆角半径（避开圆角之外的桌面），
    /// 上下各内缩 2pt。抓回来按 `bandHeight` 切成若干行，只用最上和最下那两行——
    /// 它们正好各是一条纯玻璃，中间的行全是图标与文字，不看。
    static func probe(in rect: CGRect, cornerRadius: CGFloat) -> CGRect {
        // 条排完版之前会短于两个圆角，这时没有可采的玻璃，交给调用方跳过
        guard rect.width > cornerRadius * 2, rect.height > edgeInset * 2 else { return .null }
        return CGRect(x: rect.minX + cornerRadius, y: rect.minY + edgeInset,
                      width: rect.width - cornerRadius * 2, height: rect.height - edgeInset * 2)
    }

    func sample(probe: CGRect, on display: CGDirectDisplayID) {
        guard probe.width > 1, probe.height > Self.bandHeight * 2 else { return }
        pending = (probe, display)
        drain()
    }

    /// 去抖是限流，不是丢弃。丢掉的那次往往正是最要紧的一次——簇面板紧接着预览卡弹出来，
    /// 它那次采样落在去抖窗口里被丢掉，面板就一直顶着上一层浮层留下的明暗，
    /// 直到两秒后的兜底采样才转过来（实测）。
    private func drain() {
        guard !sampling, let next = pending else { return }
        let wait = Self.minInterval - Date().timeIntervalSince(lastSample)
        guard wait <= 0 else {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.scheduled = false
                self?.drain()
            }
            return
        }
        pending = nil
        sampling = true
        lastSample = Date()
        Task { @MainActor [weak self] in
            await self?.run(probe: next.probe, display: next.display)
            self?.sampling = false
            self?.drain()
        }
    }

    @MainActor private func run(probe: CGRect, display: CGDirectDisplayID) async {
        do {
            let active: SCContentFilter
            if let filter, filterDisplay == display, filterAge < Self.filterLifetime {
                active = filter
            } else {
                active = try await Self.makeFilter(display)
                filter = active
                filterDisplay = display
                filterAge = 0
            }
            filterAge += 1
            // ScreenCaptureKit 会保持源矩形的宽高比，比例对不上就在边上补黑，而补出来的
            // 黑边会被当成「背景很暗」——实测把一条 802×73 抓成 16×12，只有最上面两行
            // 有内容，其余十行全黑。所以先按行高定行数，再让宽度去迁就比例。
            let rows = max(2, Int((probe.height / Self.bandHeight).rounded()))
            let columns = max(2, Int((CGFloat(rows) * probe.width / probe.height).rounded()))
            let width = probe.height * CGFloat(columns) / CGFloat(rows)
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: probe.midX - width / 2, y: probe.minY,
                                       width: width, height: probe.height)
            config.width = columns
            config.height = rows
            config.showsCursor = false
            config.captureResolution = .nominal
            let image = try await SCScreenshotManager.captureImage(contentFilter: active,
                                                                   configuration: config)
            reportedFailure = nil
            guard let luminance = Self.luminance(image) else { return }
            if logged.map({ abs($0 - luminance) >= 0.05 }) ?? true {
                logged = luminance
                Timeline.log(String(format: "玻璃板亮度  %@ %.3f", name, luminance))
            }
            let next: ColorScheme
            if luminance < Self.darkBelow { next = .dark }
            else if luminance > Self.lightAbove { next = .light }
            else { return }   // 落在迟滞带里，保持不动
            guard next != scheme else { return }
            scheme = next
            onChange?(next)
        } catch {
            // 扔掉过滤器，下一次重建
            filter = nil
            let reason = "\(probe)（屏 \(display)）：\(error)"
            if reportedFailure != reason {
                reportedFailure = reason
                Timeline.log("⚠️ \(name)的玻璃板亮度采不到，文字明暗暂时固定跟随系统外观：\(reason)")
            }
        }
    }

    /// 不排除任何窗口：要的就是含我们自己那块玻璃在内的合成结果。
    private static func makeFilter(_ display: CGDirectDisplayID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let target = content.displays.first(where: { $0.displayID == display }) else {
            throw MissingDisplay(id: display, listed: content.displays.map(\.displayID))
        }
        return SCContentFilter(display: target, excludingWindows: [])
    }

    /// 实测会发生：拔插显示器之后，ScreenCaptureKit 的显示器列表会空一阵子。
    private struct MissingDisplay: Error, CustomStringConvertible {
        let id: CGDirectDisplayID
        let listed: [CGDirectDisplayID]
        var description: String {
            "ScreenCaptureKit 没有列出显示器 \(id)，它列出的是 \(listed)"
        }
    }

    /// 逐列取「最上一行与最下一行的平均」，再取各列的中位数。
    ///
    /// 只取两条边是因为中间全是图标与文字；两条边取平均而不是只用一条，是因为
    /// 玻璃是透的，条上下 77pt 之内背景常常自己就是渐变的——实测一次窗口下沿正好压在
    /// 条上，上缘 0.47、下缘 0.76，而文字所在的中间是 0.70。两端取平均就落在中间。
    /// 取中位数是因为角标与运行指示点会各自探进纯玻璃里一点点，求平均会被它们拉偏。
    private static func luminance(_ image: CGImage) -> Double? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func value(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return 0.2126 * Double(pixels[i]) / 255
                + 0.7152 * Double(pixels[i + 1]) / 255
                + 0.0722 * Double(pixels[i + 2]) / 255
        }
        var columnValues = (0..<w).map { (value($0, 0) + value($0, h - 1)) / 2 }
        columnValues.sort()
        return columnValues[columnValues.count / 2]
    }
}
