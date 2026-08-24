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
struct DockGlass: NSViewRepresentable {
    let cornerRadius: CGFloat

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

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        Self.configure(glass, cornerRadius: cornerRadius)
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.cornerRadius = cornerRadius
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

// 内容明暗跟着背景走这件事：**Liquid Glass 做不到，别再试了。**
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
