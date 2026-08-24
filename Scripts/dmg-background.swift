// 画 DMG 窗口的背景图（@1x 与 @2x 各一张 PNG）。
//
// 为什么用 Swift 现画而不是放一张 PNG 进仓库：图上的坐标必须和 make-dmg.sh 里
// 图标摆位的坐标严格对齐——写死成二进制图片后，改窗口尺寸就得重画。
// 这里两边共用同一组常量，改一个数字就整体跟着动，且仓库仍然是纯文本。
//
// 画面上只有四样东西：底色、字标、一个指向 Applications 的箭头、一行说明。
// 初版另外画了底部的 slab 与一排槽位、两个图标位置上的空插槽、虚线轨道与实心三角
// 箭头，都已删去。slab 与槽位就是应用图标本身的形状，而那个图标此刻正摆在这张
// 背景图上，等于把同一件东西画了两遍；空插槽让两个图标看起来像是没加载出来的
// 占位框；虚线加实心三角则是另一个年代的画法。
//
// 用法: swift Scripts/dmg-background.swift <输出目录> <版本号>
//   产物: <输出目录>/background.png、<输出目录>/background@2x.png

import AppKit

// ── 版面常量（单位: pt，原点在左上角）────────────────────────────────
// W/H 是访达窗口「内容区」的尺寸，不含标题栏。make-dmg.sh 里的窗口高度要另加标题栏。
let W: CGFloat = 620
let H: CGFloat = 372

let iconY: CGFloat = 180          // 两个图标的中心 y
let appIconX: CGFloat = 170       // Dockline.app 的中心 x
let dstIconX: CGFloat = 450       // Applications 的中心 x
let iconSide: CGFloat = 128       // 与 make-dmg.sh 的 ICON_SIZE 一致，箭头据此让位

// ── 取自 Resources/Dockline.icon/icon.json 与 Assets/*.svg 的配色 ──────
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}
let bgTop = rgb(0x262B33)      // icon.json 的 display-p3 渐变，换算到 sRGB
let bgBottom = rgb(0x15181D)
let amber = rgb(0xFFB03A)      // layer4-amber.svg 两个端点的中间值
let textPrimary = rgb(0xE9EDF3)
let textSecondary = rgb(0x8A929F)
let textFaint = rgb(0x555C67)

// ── 左上原点的坐标助手（AppKit 的画布原点在左下）──────────────────────
func rectTL(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: H - y - h, width: w, height: h)
}
func text(_ s: String, _ font: NSFont, _ color: NSColor, topY: CGFloat,
          kern: CGFloat = 0, align: NSTextAlignment = .center,
          x: CGFloat = 0, width: CGFloat = W) {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern,
    ]).draw(in: rectTL(x, topY, width, font.pointSize * 2))
}

/// 两个图标之间的箭头。一根线加一个折角，不用实心三角——后者在这个尺寸上
/// 是画面里最重的一块墨，而它要传达的信息（往右拖）本来只需要一个方向。
func drawArrow() {
    let y = H - iconY
    let mid = (appIconX + dstIconX) / 2
    let start = mid - 38
    let end = mid + 38
    let head: CGFloat = 7

    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: start, y: y))
    shaft.line(to: NSPoint(x: end - head, y: y))
    shaft.lineWidth = 1.75
    shaft.lineCapStyle = .round
    amber.withAlphaComponent(0.65).setStroke()
    shaft.stroke()

    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: end - head, y: y + head))
    tip.line(to: NSPoint(x: end, y: y))
    tip.line(to: NSPoint(x: end - head, y: y - head))
    tip.lineWidth = 1.75
    tip.lineCapStyle = .round
    tip.lineJoinStyle = .round
    amber.setStroke()
    tip.stroke()
}

func draw(version: String) {
    NSGradient(colors: [bgTop, bgBottom])!
        .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)), angle: -90)

    text("Dockline", .systemFont(ofSize: 25, weight: .medium), textPrimary,
         topY: 46, kern: 1.6)
    drawArrow()
    text("拖到 Applications 完成安装", .systemFont(ofSize: 12, weight: .regular),
         textSecondary, topY: 298)
    text("v\(version)", .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
         textFaint, topY: 338, align: .right, x: 0, width: W - 22)
}

func render(scale: CGFloat, to url: URL, version: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("无法创建 \(scale)x 位图") }
    rep.size = NSSize(width: W, height: H)   // 让绘制以 pt 为单位，scale 只影响像素数

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    draw(version: version)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败")
    }
    try! png.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: dmg-background.swift <输出目录> <版本号>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
let version = args[2]
render(scale: 1, to: outDir.appendingPathComponent("background.png"), version: version)
render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"), version: version)
print("背景图已生成: \(outDir.path)/background.png (+@2x)")
