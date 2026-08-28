import AppKit
import SwiftUI

/// 玻璃板的明暗（计划书 §3.1）。**由合成器推送，本进程既不抓图也不轮询。**
///
/// Liquid Glass 自己就会算背景亮度、把明暗施加到内容上，但只对高 ≤64pt 的玻璃开；
/// 一根 77pt 的条够不着那道闸。**可闸门管的是那块玻璃自己的内容，不管谁来读这个读数**
/// ——于是在条底下垫一块 ≤64pt 的玻璃当探针：它在闸门之内，窗口服务器照常给它算，
/// 我们只取读数，画面上并不要它。
///
/// 探针 alpha 压到 0.01：仍然跟得准，而肉眼看不见（逐像素比过）。恰好为 0 就不跟了。
/// 整条实测记录、试过并否掉的绕法、两个容易把这条路误判成死路的坑，都在 `DockGlass` 里。
///
/// 它取代的是先前那套 ScreenCaptureKit 取色：每 2 秒抓一次屏，而每次抓屏都会点亮系统的
/// 录屏指示灯——那盏灯本身又搅动窗口名单，逼出我们自己的完整对账（见 `WindowListWatch`）。
/// 整套东西连同那个自激回路一起没有了。
struct BackdropProbe: NSViewRepresentable {
    /// 只用于日志：条与浮层各有一个，两条 bar 又各有一份，读数要能分辨是谁的。
    let name: String
    let onChange: (ColorScheme) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(name: name)
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    // MARK: -

    final class ProbeView: NSView {
        /// 探针高度上限。玻璃高到 66pt 那道闸就关了（见 `DockGlass`），留出余量。
        private static let ceiling: CGFloat = 60
        /// 看不见，但不能是 0——实测 alpha 恰好为 0 时合成器就不给它算了。
        private static let opacity: CGFloat = 0.01

        /// 构造时就要有：头一次读数在 `init` 里就发生了，等外面赋值来不及。
        private let name: String
        var onChange: ((ColorScheme) -> Void)?

        /// 玻璃此刻挂在谁身上。见 `viewDidMoveToWindow`——它不挂在本视图上。
        private var anchor: NSView?

        private let glass = NSGlassEffectView()
        /// 自适应的结果作用在内容视图的 `effectiveAppearance` 上，所以读数口就是它。
        /// 内容视图必须**是** `NSTextField`，玻璃才走内容明暗自适应那一档（见 `DockGlass`）。
        private let readout = Readout(labelWithString: " ")
        private var widthConstraint: NSLayoutConstraint!
        private var heightConstraint: NSLayoutConstraint!
        private var reported: ColorScheme?
        private var warnedAboutHeight = false

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
            // **外观钉死。** 条的内容套着 `.environment(\.colorScheme, backdropScheme)`，
            // 而探针垫在同一个 `.background` 里，会连这个环境一起继承——于是探针的读数
            // 成了自己上一次读数的函数，明暗在两档之间自己抖起来（实测三秒翻三次）。
            // 钉住之后玻璃的自适应照常盖在它上面，环是断的。
            // 外观要钉在**玻璃自己**身上，不能钉在本视图上等它继承：玻璃已经不是本视图的
            // 子视图了（见 `viewDidMoveToWindow`），继承来的是根视图的外观。
            glass.appearance = NSAppearance(named: .aqua)
            readout.textColor = .clear
            readout.translatesAutoresizingMaskIntoConstraints = false
            widthConstraint = readout.widthAnchor.constraint(equalToConstant: 1)
            heightConstraint = readout.heightAnchor.constraint(equalToConstant: 1)
            NSLayoutConstraint.activate([widthConstraint, heightConstraint])
            readout.onAppearanceChange = { [weak self] in self?.publish() }

            glass.contentView = readout
            glass.alphaValue = Self.opacity
        }

        required init?(coder: NSCoder) { fatalError("不从 nib 加载") }

        /// **玻璃挂到窗口根视图上去，不挂在本视图身上。**
        ///
        /// 条与浮层的玻璃套在一个 `NSGlassEffectContainerView` 里，为的是将来两块玻璃能
        /// 互相形变（见 `BarPanel`）。而那个容器会把子树里的玻璃**成批**合成，成批之后
        /// 不再按每块玻璃各自的 alpha 走——探针那个 0.01 就此失效，画面上变成条的玻璃里
        /// 又套着一块玻璃。实测如此。
        ///
        /// 探针本来也不是界面的一部分，它是一件量具。位置照旧由 SwiftUI 排（留在树里的是
        /// 这个空占位视图），真正那块玻璃挂到容器**外面**，两件事就此各归各的。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let root = window?.contentView else {
                // 浮层收回去时占位视图会离场，量具跟着撤掉，否则会留在画面上不走
                glass.removeFromSuperview()
                anchor = nil
                return
            }
            guard glass.superview !== root else { return }
            // 压在最底下。半透明的玻璃盖在探针上面不算遮挡，不影响读数（见 `DockGlass`
            // 里那张实测表）；反过来盖住它的若是不透明窗口，读数才会停。
            root.addSubview(glass, positioned: .below, relativeTo: nil)
            anchor = root
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let width = max(bounds.width, 1)
            let height = max(min(bounds.height, Self.ceiling), 1)
            widthConstraint.constant = width
            heightConstraint.constant = height
            // 玻璃走 autoresizing，不吃上面那两条约束，尺寸必须明写——不写它就是 0×0，
            // 而 0×0 的玻璃什么都不报也不报错，症状是「明暗从此不动」，指不到原因。
            let box = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                             width: width, height: height)
            // 挂在别人身上，位置就要换算过去。还没进窗口时无从谈起，等 `viewDidMoveToWindow`。
            guard let anchor else { return }
            glass.frame = convert(box, to: anchor)
            glass.layoutSubtreeIfNeeded()
            // 越过那道闸同样是静悄悄地失效，必须说出来
            if glass.frame.height > 64, !warnedAboutHeight {
                warnedAboutHeight = true
                Timeline.log("⚠️ 亮度探针长到了 \(Int(glass.frame.height))pt，越过 64pt 那道闸，"
                             + "文字明暗将不再跟随背景")
            }
        }

        private func publish() {
            let dark = readout.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let scheme: ColorScheme = dark ? .dark : .light
            guard scheme != reported else { return }
            reported = scheme
            Timeline.log("玻璃板明暗  \(name) \(scheme == .dark ? "暗底" : "亮底")")
            onChange?(scheme)
        }

        private final class Readout: NSTextField {
            var onAppearanceChange: (() -> Void)?
            override func viewDidChangeEffectiveAppearance() {
                super.viewDidChangeEffectiveAppearance()
                onAppearanceChange?()
            }
        }
    }
}
