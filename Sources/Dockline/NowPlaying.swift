import AppKit
import SwiftUI

/// 此刻在放的东西（实时状态设计 §5）。
///
/// **它不是一档 `Session.Salience`。** 那三档说的是「谁在等谁」，而播放对这个问题的
/// 回答是「没人在等谁」：它不会结束，也永远不该抢注意力。把它塞进那套排序里，等于让一件
/// 不参与注意力竞争的事进了注意力队列。两者因此是并列的两种状态，不是同一种的两档。
struct NowPlaying: Equatable {
    /// 谁在放。条靠它找到对应那一格。
    let bundleID: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    /// 播放位置，以及**这个读数是什么时候取的**。
    ///
    /// 进度靠这两个数在本地推算，不去轮询：轮询正是这条链路想省掉的东西，
    /// 而有了时间戳就只需要在换歌、暂停这些真正的变化上收一次推送。
    let elapsed: Double
    let timestamp: Date
    /// 播放速率。0 表示停着。
    let rate: Double
    let playing: Bool
    /// 封面的标识。桥只在它变了的时候才把几十 KB 的图重新传一遍。
    let artworkID: String?
    let artwork: NSImage?
    /// 从封面里取出来的主色。格子的标签区与面板的底都用它——
    /// 一个元素同时回答三件事：哪一格在发声、换没换歌、以及这首歌长什么样。
    let tint: Color?

    /// 此刻播到哪儿了。按上报时刻往前推，不必再问一次。
    func position(at now: Date) -> Double {
        guard playing, rate > 0 else { return elapsed }
        let advanced = elapsed + now.timeIntervalSince(timestamp) * rate
        guard let duration, duration > 0 else { return max(0, advanced) }
        return min(max(0, advanced), duration)
    }

    /// 格子第一行：在放什么。没有标题就退回 App 自己的名字，由调用方补。
    var line: String? { title }
    /// 格子第二行：谁唱的。没有歌手就用专辑——两样都没有就不占第二行。
    var subline: String? { artist ?? album }
}

/// 能发给播放源的指令。
enum MediaCommand: String {
    case play, pause, toggle, next, previous
}

/// 从桥那边读「正在播放」，以及把控制指令发回去。
///
/// 桥是 `/usr/bin/perl` 加一个我们自己的 dylib（见 `Bridge/nowplaying.m` 里那段说明）：
/// MediaRemote 只答复平台二进制，所以调用必须发生在 perl 的身份底下。
final class NowPlayingReader {
    var onChange: ((NowPlaying?) -> Void)?

    private var stream: Process?
    private var buffer = Data()
    /// 上一次拿到的封面。桥只在换歌时重传，中间那些推送要靠这里粘住。
    private var artwork: (id: String, image: NSImage, tint: Color)?

    private static var script: URL? {
        Bundle.main.url(forResource: "nowplaying", withExtension: "pl")
    }

    private static var library: URL? {
        Bundle.main.url(forResource: "libnowplaying", withExtension: "dylib")
    }

    func start() {
        guard let script = Self.script, let library = Self.library else {
            Timeline.log("⚠️ 播放状态不可用：bundle 里没有 nowplaying.pl 或 libnowplaying.dylib")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, library.path, "stream"]
        let output = Pipe()
        task.standardOutput = output
        // stdin 要接一根管道并且**一直开着**：桥读它读到 EOF 就退出，
        // 那正是「条没了，它跟着走」这条规则的实现——两端都不必去盯对方的 pid。
        task.standardInput = Pipe()
        task.standardError = FileHandle.nullDevice
        // 读回调跑在自己的线程上，而这里的状态与下游全在主线程。整条链路只在这一处
        // 换线程，换完之后不再有并发。
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.restart() }
        }
        do {
            try task.run()
        } catch {
            Timeline.log("⚠️ 播放状态不可用：起不了桥进程（\(error)）")
            return
        }
        stream = task
    }

    /// 桥意外退出了。这是本文件里唯一一处恢复：它是个外部进程，被系统收掉、
    /// 被更新换掉都可能发生，而它一走播放状态就永远停在最后一帧。
    /// 重来之前先报一声——悄悄重启会把一个反复崩溃的桥变成看不见的忙等。
    private func restart() {
        guard stream != nil else { return }   // 主动停的，不重来
        stream = nil
        buffer.removeAll()
        Timeline.log("⚠️ 播放状态的桥退出了，重开一条")
        onChange?(nil)
        start()
    }

    func stop() {
        let task = stream
        stream = nil
        task?.terminate()
    }

    /// 发一条控制指令。每条指令起一个短命的进程——指令是稀疏的（一次点击一条），
    /// 为它维持一条常驻的写通道不值得，而且那样还得自己处理指令与推送的交错。
    func send(_ command: MediaCommand) {
        guard let script = Self.script, let library = Self.library else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, library.path, "command", command.rawValue]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            Timeline.log("⚠️ 播放控制发不出去：\(error)")
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<end]
            buffer = buffer[(end + 1)...]
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else {
                Timeline.log("⚠️ 播放状态收到读不懂的一行")
                continue
            }
            onChange?(parse(object))
        }
    }

    private func parse(_ object: [String: Any]) -> NowPlaying? {
        // 没有 bundleID 就是此刻没有任何播放源。这不是错误，是一种正常状态。
        guard let bundleID = object["bundleID"] as? String, !bundleID.isEmpty else {
            artwork = nil
            return nil
        }
        // 播放器开着、但一首歌都没加载时，它照样注册成播放源（实测：网易云刚启动就是
        // 这样，停着、什么字段都没有）。那不是「在放东西」，格子上也就没有可说的，
        // 更不该为它亮一个均衡器。
        guard object["title"] is String || object["artist"] is String else {
            artwork = nil
            return nil
        }
        let artworkID = object["artworkID"] as? String
        if let encoded = object["artwork"] as? String,
           let data = Data(base64Encoded: encoded),
           let image = NSImage(data: data) {
            artwork = (artworkID ?? "", image, Artwork.tint(image))
        } else if let artworkID, artwork?.id != artworkID {
            // 换了封面标识却没带图：粘住的那张已经不是这首歌的了
            artwork = nil
        }
        return NowPlaying(
            bundleID: bundleID,
            title: object["title"] as? String,
            artist: object["artist"] as? String,
            album: object["album"] as? String,
            duration: object["duration"] as? Double,
            elapsed: object["elapsed"] as? Double ?? 0,
            timestamp: (object["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? Date(),
            rate: object["rate"] as? Double ?? 0,
            playing: object["playing"] as? Bool ?? false,
            artworkID: artworkID,
            artwork: artwork?.image,
            tint: artwork?.tint)
    }
}

/// 从封面里取一个能用的主色。
enum Artwork {
    /// 取的是**占地方的那个色相**，不是最艳的那个像素。
    ///
    /// 先前挑单个最艳像素，结果是一张以蓝为主的封面给出了粉色：单个像素本来就是噪声，
    /// JPEG 的一块边缘瑕疵就能当选。这里改成按色相分桶投票，每个像素按自己的鲜艳程度
    /// 投，于是一大片中等鲜艳的蓝压得过几个极艳的杂点。
    ///
    /// 桶内的色相用单位向量求平均：色相是环形的，350° 与 10° 直接取算术平均会得到 180°，
    /// 正好是它们的补色。
    static func tint(_ image: NSImage) -> Color {
        let side = 32
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .accentColor
        }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .accentColor }
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))

        let bins = 24
        var weights = [CGFloat](repeating: 0, count: bins)
        var vectors = [(x: CGFloat, y: CGFloat)](repeating: (0, 0), count: bins)
        var saturations = [CGFloat](repeating: 0, count: bins)
        var brightnesses = [CGFloat](repeating: 0, count: bins)
        var litCount = 0
        var litBrightness: CGFloat = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(red: CGFloat(pixels[index]) / 255,
                                green: CGFloat(pixels[index + 1]) / 255,
                                blue: CGFloat(pixels[index + 2]) / 255,
                                alpha: 1).usingColorSpace(.deviceRGB) ?? .gray
            let saturation = color.saturationComponent
            let brightness = color.brightnessComponent
            // 太暗的像素色相不可信：黑边和阴影里剩下的那点色差全是噪声
            guard brightness > 0.18 else { continue }
            litCount += 1
            litBrightness += brightness
            // 鲜艳度取平方：一个 s=0.9 的像素只抵九个 s=0.3 的，
            // 少数几个杂点因此压不过一整片底色
            let weight = saturation * saturation * brightness
            let hue = color.hueComponent
            let bin = min(Int(hue * CGFloat(bins)), bins - 1)
            let radians = hue * 2 * .pi
            weights[bin] += weight
            vectors[bin] = (vectors[bin].x + cos(radians) * weight,
                            vectors[bin].y + sin(radians) * weight)
            saturations[bin] += saturation * weight
            brightnesses[bin] += brightness * weight
        }

        // 整张封面没有一处有颜色（黑白照、纯灰底）。这不是取色失败，
        // 它的主色本来就是灰的，那就给灰——不为它编一个颜色出来。
        guard litCount > 0 else { return .accentColor }
        guard let top = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[top] > 0
        else {
            return Color(nsColor: NSColor(white: clampBrightness(litBrightness / CGFloat(litCount)),
                                          alpha: 1))
        }
        let weight = weights[top]
        let hue = atan2(vectors[top].y, vectors[top].x) / (2 * .pi)
        // 压明度是为了在半透明的条上还看得见：浅色外观下太暗的读不出，深色外观下太亮的发白。
        // 鲜艳度只封顶不托底——托底等于给一张本来素净的封面凭空造一个颜色。
        let tuned = NSColor(hue: hue < 0 ? hue + 1 : hue,
                            saturation: min(saturations[top] / weight, 0.85),
                            brightness: clampBrightness(brightnesses[top] / weight),
                            alpha: 1)
        return Color(nsColor: tuned)
    }

    private static func clampBrightness(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.45), 0.9)
    }
}
