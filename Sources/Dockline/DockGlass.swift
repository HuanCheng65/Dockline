import AppKit
import SwiftUI

/// 条与扇面的背板。
///
/// 不走 SwiftUI 的 `glassEffect`：它只暴露 `.regular` / `.clear` 两档，而系统程序坞用的是
/// AppKit 内部的另一档材质。更要紧的是本体是 nonactivating 面板、永远不会成为 key window，
/// 玻璃因此按「非活跃」外观再压一层，看起来就厚、就灰——系统程序坞没有这个问题。
///
/// 私有面：内部材质档位与面板的活跃外观（见 `BarPanel`）。
/// 全部是 AppKit 内部实现，不需要关 SIP，风险面是「系统更新后内部名字变了」——
/// 因此逐个 `responds(to:)` 自检，缺了就跳过并报出来，绝不静默。
/// 失效的后果只是回到 `.clear` 的观感，不影响任何功能。
///
/// **内容装在玻璃里面，不是垫在玻璃底下。** 前一种写法（内容与 `DockGlass` 并排放进
/// 一个 ZStack）在画面上看不出区别，但玻璃对内容的那一套——折射、边缘的高光、内容
/// 明暗跟着背景走——全都作用在 `contentView` 上，并排的内容一样都拿不到。
///
/// 尺寸也跟着换了主人：由内容自己量出来（见 `GlassRuler`），外面不再另算一份。
/// 原先浮层那三档各有一套与视图树平行的尺寸算法，改一处就要记得改两处。
///
/// **尺寸从 `sizeThatFits` 报出去，不要在外面再套一层 `.frame`，更不要加 `Animatable`。**
/// 这条是量出来的：SwiftUI 会把 representable 那个 NSView 的 frame 逐帧插值地设过去
/// （实测一次 0.6 秒的 spring 里 `setFrameSize` 被调用 114 次，宽度从 102 一路走到 300），
/// 玻璃与它装着的内容因此跟着一起流动。而**加上 `Animatable` 就等于告诉 SwiftUI「这个
/// 视图自己管动画」，那份内建的逐帧插值当场消失**，只剩一步到位的跳变。
struct DockGlass<Content: View>: NSViewRepresentable {
    /// 内容量出来的理想尺寸，见 `GlassRuler`。
    let size: CGSize
    let cornerRadius: CGFloat
    let content: Content

    init(size: CGSize, cornerRadius: CGFloat, @ViewBuilder content: () -> Content) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    /// 内部材质档位。逆向所得的全表，记在这里免得下次又要重新查。
    /// 取 `.appIcons` 而不是 `.dock`：实测更接近系统程序坞的观感。
    enum Variant: Int {
        case regular = 0, clear = 1, dock = 2, appIcons = 3, widgets = 4, text = 5
        case avplayer = 6, facetime = 7, controlCenter = 8, notificationCenter = 9
        case monogram = 10, bubbles = 11, identity = 12, focusBorder = 13
        case focusPlatter = 14, keyboard = 15, sidebar = 16, abuttedSidebar = 17
        case inspector = 18, control = 19, loupe = 20, slider = 21
        case camera = 22, cartouchePopover = 23
    }

    /// 玻璃与宿主之间的那一层。**裁切与定位都归它。**
    ///
    /// 玻璃的 frame 由 SwiftUI 逐帧插值地设过去，这一层是它的 `contentView`、跟着一起变，
    /// 所以它的边界就是「此刻玻璃有多大」。宿主则**不跟着缩**：它永远是内容的理想尺寸，
    /// 底边贴着这一层的底边（AppKit 非翻转坐标里 y=0 就是底边），水平居中。
    /// 于是玻璃长大时标题那一行原地不动，上面的东西从它上方一点点露出来。
    ///
    /// 让宿主跟着一起缩是不行的，试过：宿主并不把自己的尺寸传给里面那棵 SwiftUI 树，
    /// 树照自己的理想尺寸排版（实测换档时卡片一帧就到终态，中间没有任何一个值），
    /// 结果只是被从**中间**裁开——标题行跟着上下滑，逐帧看就是穿帮。
    final class ClipBox: NSView {
        /// 内容的理想尺寸，由 `DockGlass.size` 给。
        var contentSize: CGSize = .zero {
            didSet {
                guard contentSize != oldValue else { return }
                needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            guard let content = subviews.first else { return }
            content.frame = NSRect(x: ((bounds.width - contentSize.width) / 2).rounded(),
                                   y: 0,
                                   width: contentSize.width,
                                   height: contentSize.height)
        }
    }

    @MainActor
    final class Coordinator {
        /// 真正装进玻璃、真正画出来的那一份。
        let host: NSHostingView<Content>
        /// 装着宿主的那一层，见 `ClipBox`。
        let box = ClipBox()

        init(content: Content) {
            host = NSHostingView(rootView: content)
            // **画的那一份不许发布固有尺寸。** 玻璃把 `contentView` 的四条边钉死在自己
            // 身上，宿主再报一份固有尺寸，就与 SwiftUI 定下的 frame 正面相撞：约束引擎
            // 每一轮破一条约束、破完又把视图标脏，窗口被逼着一轮轮重来，最后死在
            //「Update Constraints 次数比窗口里的视图还多」这条 NSGenericException 上。
            // 症状是启动几秒后闪退，中间还夹着「条只剩一个点」。
            host.sizingOptions = []
            // 内容压根没在动，只有玻璃在动（见 `updateNSView`）。所以它整张会画在玻璃
            // 外面——「内容先蹦出来、容器随后才追上」就是这么来的。裁到玻璃此刻的边界，
            // 那一段就变成了**揭开**。裁与定位都在 `ClipBox` 里。
            box.wantsLayer = true
            box.layer?.masksToBounds = true
            box.addSubview(host)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        Self.configure(glass, cornerRadius: cornerRadius)
        context.coordinator.box.contentSize = size
        context.coordinator.box.layer?.cornerRadius = cornerRadius
        glass.contentView = context.coordinator.box
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.cornerRadius = cornerRadius
        // 玻璃在动画期间由 SwiftUI 逐帧改 frame，`ClipBox` 跟着变；宿主守着这个理想尺寸
        // 不动，底边因此始终对齐。见 `ClipBox`。
        context.coordinator.box.contentSize = size
        context.coordinator.box.layer?.cornerRadius = cornerRadius
        // 跟着外面那次事务改。**但别指望它能让玻璃里的内容也动起来**——实测不会：
        // 事务里确实带着那条 spring（`FluidSpringAnimation(response: 0.28)` 打得出来），
        // 换档时卡片仍然一帧从 124×26 跳到 168×142，中间没有任何一个值。
        // 赋 `rootView` 只是排一次更新，真正的更新在事务作用域之外才跑；
        // 在这里补一次 `layoutSubtreeIfNeeded` 也不改变这一点（试过）。
        // 内容与玻璃对齐靠的是宿主那层裁切，见 `Coordinator.init`。
        withTransaction(context.transaction) {
            context.coordinator.host.rootView = content
        }
    }

    /// 玻璃就是内容量出来的那么大，**不听提议**。
    ///
    /// 听提议是错的：浮层待在一个铺满面板的 ZStack 里，提议就是整块屏（实测玻璃因此被
    /// 设成 1470×795，还引出一轮约 460ms 的布局循环）。要定宽定高的地方（条的高度）
    /// 由调用方在 `size` 里写死，不靠这里去接。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView glass: NSGlassEffectView,
                      context: Context) -> CGSize? {
        size
    }

    /// 三处玻璃（条、簇面板、预览卡）共用的配置，只此一份。
    static func configure(_ glass: NSGlassEffectView, cornerRadius: CGFloat) {
        glass.style = .clear
        // nil 表示不额外指定染色，材质自身的自适应外观照常
        glass.tintColor = nil
        glass.cornerRadius = cornerRadius
        tune(glass, "_variant", Variant.appIcons.rawValue)
        // 另有 _scrimState / _subduedState 可以再去掉两层压暗。实测过头——
        // 条会透到快看不见边界，图标像浮在桌面上。材质档位自己的配比是对的，不再动。
    }

    static func tune(_ glass: NSGlassEffectView, _ key: String, _ value: Int) {
        guard glass.responds(to: Selector("set\(key):")) else {
            Timeline.log("⚠️ 玻璃材质参数 \(key) 不存在，跳过——系统更新可能改了内部名字")
            return
        }
        glass.setValue(value, forKey: key)
    }
}

/// 量一段 SwiftUI 内容的理想尺寸。
///
/// 玻璃的内容装在自己的 `NSHostingView` 里（见 `DockGlass`），SwiftUI 那边因此看不见它
/// 有多大。这把尺子把这个数补回去，而且是在 SwiftUI 那一侧补——量出来的数当作 `.frame`
/// 的值传下去，spring 于是有起点也有终点。换成在 `sizeThatFits` 里量就只剩跳变。
///
/// 尺子**从不进任何视图树**：因此既不参与窗口的约束引擎（进去就会与玻璃钉在 contentView
/// 上的那几条约束对撞，把窗口逼进无穷次 Update Constraints），也不跑内容里的 `.onAppear`
/// / `.task`——实测只有进了窗口的那一份会跑，浮层里每 1.2 秒抓一张缩略图的循环不会被量出
/// 第二份来。
///
/// **但它照样会把内容里的 `NSViewRepresentable` 整套实例化一遍。** 那些 NSView 建出来了，
/// 只是永远进不了窗口。凡是「一建出来就往外登记自己」的表示层都得自己认这一条，
/// 否则尺子那份会用同样的身份把真正画出来的那份挤掉，而且一路不报错——
/// `ZoneView` 因此只在进了窗口之后才入册。
///
/// 每种内容各留一把，反复改 `rootView` 而不是每次新建：换档期间 body 一帧跑一次，
/// 每帧新建一个宿主视图是白扔的。
@MainActor
enum GlassRuler {
    private static var rulers: [ObjectIdentifier: NSView] = [:]

    static func size<V: View>(of content: V) -> CGSize {
        let key = ObjectIdentifier(V.self)
        let ruler: NSHostingView<V>
        if let cached = rulers[key] as? NSHostingView<V> {
            ruler = cached
        } else {
            ruler = NSHostingView(rootView: content)
            ruler.sizingOptions = [.intrinsicContentSize]
            rulers[key] = ruler
        }
        ruler.rootView = content
        let size = ruler.intrinsicContentSize
        // 固有尺寸缺一轴时 AppKit 返回 -1，玻璃会就此塌掉。内容自己没表达宽高，
        // 谁也替它猜不出来——说出来，别让它变成一个说不清来由的点。
        if size.width < 0 || size.height < 0 {
            Timeline.log("⚠️ \(V.self) 报不出固有尺寸 \(size)——玻璃会塌，给内容补上尺寸约束")
        }
        return CGSize(width: max(size.width, 0), height: max(size.height, 0))
    }
}

// 内容明暗跟着背景走这件事。
//
// 下面这一整段的结论「只能自己采样」**已经被推翻**，新办法见本段末尾的「后来」。
// 但过程照原样留着：它记的是一条条试过并否掉的路，而那份清单本身才是这段的价值。
//
// 机制是有的：`CABackdropLayer` 由窗口服务器持续算背景亮度，通过
// `backdropLayer:didChangeLuma:` 送给 SwiftUI 的 `SDFLayer`（它有 `currentLuminance`
// 与 `backdropObserver` 两个 ivar），玻璃据此算出 contentColorScheme 施加到内容上
// （`_adaptationDebugDescription` 印得出来）。但有一道尺寸闸：
//
//     玻璃高 ≤ 64pt   backdrop 的 tracksLuma = 1，自适应生效
//     玻璃高 ≥ 66pt   backdrop 的 tracksLuma = 0，contentColorScheme 恒 light
//
// 宽度无关（900×24 照样生效），与谁决定几何无关，与 contentView 是什么无关，
// SwiftUI 的 `.glassEffect` 与 AppKit 的 `NSGlassEffectView` 一视同仁。这是给
// **控件尺寸**的玻璃准备的能力，一根 77pt 高的 Dock 条（图标 57 + 20）不在射程内。
//
// 试过并否掉的绕法，都别再走一遍：
//   · contentView 放空视图 / NSHostingView 当探针 —— 只有 contentView 本身是
//     NSTextField 时玻璃才算这一档；玻璃 alpha=0 也不算。
//   · 让探针的固有尺寸去撑玻璃 —— 撑到 77 一样失效，闸门只看玻璃高度。
//   · 在 77pt 的玻璃上强开 backdrop 的 tracksLuma —— 上游 SDFLayer 不消费，无效。
//   · 自己挂一层 CABackdropLayer 开 tracksLuma 收 luma —— delegate 与父图层都收不到
//     回调，投递走的是 CA 内部的观察者（SDFLayer 的 backdropObserver），未找到注册入口。
//
// 真要做，只能自己采样条背后的亮度（见计划书 §9）。
//
// ── 后来 ───────────────────────────────────────────────────────────────────
//
// 上面那句话是错的。**闸门只管这块玻璃自己的内容，管不着别人来读这个读数。**
//
// 那就不必让 77pt 的条自己开这个能力：在条**底下**垫一块 ≤64pt 的玻璃，它在闸门
// 之内，窗口服务器照常给它算亮度；我们只读它的读数，画面上并不要它。见 `Backdrop`。
//
// 实测（macOS 26.5，逐条都是黑白底板来回翻出来的，不是推断）：
//
//   探针 alpha=1     无遮挡              ✅ 跟得准
//   探针 alpha=0.01  无遮挡              ✅ 跟得准，且**肉眼不可见**
//   探针 alpha=0     无遮挡              ❌ 不跟 —— 上面那条「alpha=0 也不算」没记错，
//                                          但闸门恰好就卡在 0：0.01 就够了
//   探针 alpha=1     被**不透明**窗口盖住 ❌ 不跟 —— 遮挡剔除会把它算掉
//   探针 alpha=0.01  垫在 77pt 条玻璃底下 ✅ 跟得准 —— 半透明的玻璃压在上面不算遮挡，
//                                          而且探针量的是窗口背后的桌面，不是条自己
//
// 可见性按逐像素比过（中灰底板）：alpha=1 的阳性对照平均差 88.5/255、99% 的像素变了；
// alpha=0.01 是平均差 0.223/255，差超过 2 的只有 240 个像素（0%），而那 240 个是探针
// 里那行字——内容留空就没有了。
//
// **读数不需要任何私有面。** 自适应的结果是作用在内容视图的 `effectiveAppearance` 上的：
// 底板白 → 内容 `NSAppearanceNameAqua`，底板黑 → `NSAppearanceNameDarkAqua`。
// 覆盖 `viewDidChangeEffectiveAppearance()` 就能收到，全是公开 API；
// `_adaptationDebugDescription` 只在查这件事的时候用得着，产线上不必碰。
//
// 另有两个坑，都害我把这条路误判成死路，写在这里免得下次再踩：
//   · 给 `NSGlassEffectView` 设了 `contentView` 之后，**玻璃会缩到内容的高度**。
//     以为在测 56pt，实际一直是 16pt——讨论那道 64pt 的闸之前先确认量的是哪个高度。
//   · 附属 App（`.accessory`）里 `NSScreen.main` 不一定是你以为的那块屏。拿它摆探针
//     和底板，两者可能落在不同的屏上，于是「怎么翻都不动」。挑屏要挑明确。
//
// 还没验的：合成器给的只有 light/dark，没有数值——`SDFLayer.currentLuminance` 的 ivar
// 类型编码是空的，按偏移读不出来。迟滞从此归系统管，我们自己那条 0.42/0.52 的带作废。
