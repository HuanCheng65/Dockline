import AppKit
import SwiftUI

/// 条的命中形状——**窗口服务器判断「这一点上有没有东西可点」用的那张形状**。
///
/// 面板不是 opaque 的，命中判定因此逐像素看这张画面缓冲：空的地方点击穿过去，落到下面的
/// 窗口上（`BarPanel` 顶上那段记的就是这条，界在 alpha 0.005）。麻烦在于**条画出来的东西
/// 一样都不在这张缓冲里**：玻璃连同它 `contentView` 里的图标、文字，全部由窗口服务器在
/// 合成时另算，本窗口的缓冲在那一整块上是透明的。
///
/// 实测（`NSWindow.windowNumber(at:)` 就是命中判定本身，同一块面板上逐段对照扫出来的）：
///
///   玻璃本身（alpha 1）                        ❌ 点不中
///   玻璃 `contentView` 里的**不透明**内容       ❌ 点不中 —— 图标与标题全在这一档
///   `NSGlassEffectContainerView` 里那张 SwiftUI 图上画的东西  ❌ 点不中 —— 容器成批合成，
///                                              整棵子树一起走服务器那条路，连不透明的板都不算
///   容器**外面**、alpha 0.01 的裸视图           ✅ 点得中
///
/// 于是这块板只能挂在容器外面，跟亮度探针同一个去处、同一个理由（见 `BackdropProbe`）。
/// 位置照旧由 SwiftUI 排——留在视图树里的是这个空占位视图，板本身挂到窗口根视图上。
///
/// **在此之前条能点是个巧合。** 那时窗口形状里唯一的东西就是探针那块 alpha 0.01 的玻璃：
/// 量出来 60pt 高（探针自己的上限）、死钉在条的中间，于是条的上下沿各约 9pt 与四个圆角
/// 一直点不中，而探针一旦收起、挪位或改尺寸，整条 bar 当场失去全部命中区。命中形状不该由
/// 一件量具顺带提供，这块板把它接过来。
struct HitPlate: NSViewRepresentable {
    let cornerRadius: CGFloat
    /// 条此刻看不见。看不见的东西不该接得住点击——命中形状要跟着可见性走。
    let hidden: Bool

    func makeNSView(context: Context) -> PlateView {
        let view = PlateView()
        view.apply(cornerRadius: cornerRadius, hidden: hidden)
        return view
    }

    func updateNSView(_ view: PlateView, context: Context) {
        view.apply(cornerRadius: cornerRadius, hidden: hidden)
    }

    // MARK: -

    final class PlateView: NSView {
        /// 看不见，但不能是 0——0 就退回全透明，命中判定又把这块跳过去了。
        /// 与探针同一个数，可见性也是同一份逐像素实测（见 `DockGlass` 末尾那张表）。
        private static let opacity: CGFloat = 0.01

        /// 真正进窗口形状的那一块。它不挂在本视图身上，见 `viewDidMoveToWindow`。
        private let plate = NSView()
        /// 板此刻挂在谁身上。
        private var anchor: NSView?

        init() {
            super.init(frame: .zero)
            plate.wantsLayer = true
            plate.layer?.backgroundColor = NSColor.black.cgColor
            // 圆角要照着条的形状来，四个角外面的点该穿过去
            plate.layer?.cornerCurve = .continuous
            plate.alphaValue = Self.opacity
        }

        required init?(coder: NSCoder) { fatalError("不从 nib 加载") }

        func apply(cornerRadius: CGFloat, hidden: Bool) {
            if plate.layer?.cornerRadius != cornerRadius {
                plate.layer?.cornerRadius = cornerRadius
            }
            if plate.isHidden != hidden { plate.isHidden = hidden }
        }

        /// 板挂到窗口根视图上去，落在玻璃容器**外面**。理由见本文件开头那张实测表。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let root = window?.contentView else {
                plate.removeFromSuperview()
                anchor = nil
                return
            }
            guard plate.superview !== root else { return }
            // 压在最底下：它是 1% 的黑，盖在玻璃上面会让条整体暗一丝
            root.addSubview(plate, positioned: .below, relativeTo: nil)
            anchor = root
            needsLayout = true
        }

        /// **位移也要跟。** `layout()` 只在尺寸变了之后才跑，而条隐藏时是被整体往下推出
        /// 窗口的——纯位移不改尺寸，不补这一句，板会停在原地继续把那一块挡着。
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // 挂在别人身上，位置就要换算过去。还没进窗口时无从谈起。
            guard let anchor else { return }
            let target = convert(bounds, to: anchor)
            guard target != plate.frame else { return }
            plate.frame = target
        }
    }
}
