import CoreGraphics
import Darwin

/// 抓一扇窗口此刻的画面，走窗口服务器手里那份后备存储（计划书 §5）。
///
/// **它补的是 ScreenCaptureKit 抓不到的那一类。** SCK 合成的是「当前正在显示的一帧」，
/// 所以 Space 不在前台的全屏窗口它给不出来——实测报 `-3811`，而那恰恰是最需要预览的一批：
/// 切过去才看得见，而看一眼的目的正是为了不切过去。同一扇窗口这条路抓得到，画面是当下的。
///
/// **它比 SCK 贵，所以只做补位。** 同口径实测（抓 + 缩到 720px）一轮 45ms，SCK 是 37ms。
/// 贵在缩放：这个接口没有输出尺寸参数，只能先拿到整幅原始像素再自己缩，而 SCK 是让
/// 合成器直接按目标尺寸出图。裸抓的 13–22ms 不是可比的数，它少了这一步。
///
/// 更要紧的是 `CGWindowListCreateImage` 在 26 的 SDK 里被标成 unavailable，Apple 随时
/// 可能真的把它拿掉；主次颠倒的话，那一天所有预览一起没。现在这样，那一天只是全屏窗口
/// 退回「暂时无法预览」。
///
/// 标注挡的是编译，不是运行——二进制兼容要求这个符号还在，所以按符号取来直接调。
/// 「标注说不让用」与「能力没了」是两件事（计划书 §6 M6 记着上一次在这里栽的跟头）。
/// 取不到符号就整条不可用，按能力探、不按系统版本号判（§2）。
public enum WindowShot {
    private typealias CreateImage =
        @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    private static let create: CreateImage? = {
        // RTLD_DEFAULT：按符号在已加载的镜像里找，不指定是哪个库
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    public static var available: Bool { create != nil }

    /// 抓一张并缩到 `width` 以内。nil = 抓不到。
    ///
    /// 缩放这一步是我们自己做的：这个接口没有输出尺寸参数，给的是窗口的原始像素，
    /// 一扇大窗口二十几 MB。SCK 那边由 `SCStreamConfiguration` 代劳同一件事。
    public static func grab(_ wid: CGWindowID, width: CGFloat) -> CGImage? {
        guard let create else { return nil }
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingBestResolution: UInt32 = (1 << 0) | (1 << 3)
        guard let full = create(.null, includingWindow, wid, ignoreFramingBestResolution)?
            .takeRetainedValue() else { return nil }
        // 拿到 CGImage 不等于拿到画面：这个接口若哪天被削弱，形状正是「给一张 1×1 的图」
        guard full.width > 1, full.height > 1 else { return nil }
        let scale = min(1, width / CGFloat(full.width))
        guard scale < 1 else { return full }
        return resize(full, to: scale)
    }

    private static func resize(_ image: CGImage, to scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        // 窗口截图的色彩空间偶尔是 CGContext 建不出上下文的那几种（灰度、索引色）。
        // 缩略图不追求色彩保真，统一画进 sRGB 即可。
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
