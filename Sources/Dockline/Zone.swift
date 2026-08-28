import AppKit
import SwiftUI

/// 条上一格、簇里一项、浮层里一张卡——它在**窗口坐标**里的位置，问 AppKit 要。
///
/// 为什么不能用 SwiftUI 的坐标读数：这些东西住在玻璃的 `contentView` 里，那是另一张
/// SwiftUI 图（见 `DockGlass`）。要把「这一格在屏幕上的哪里」凑出来，就得把三个读数相加
/// ——格子在行里、条在面板里、面板多高——而这三个由三套机制在三个不同的时刻更新，
/// 没有任何东西保证它们属于同一帧。实测翻过两次车：
///
///   · 右键命中区算到面板外面去（判定出来 y 是 −324…−262），于是一格都点不中。
///     `barFrame.minY` 是面板 795 高时量的，`panelHeight` 已经是 455 了。
///   · 玻璃有一瞬宽度为 0，行被居中到原点 −行宽/2，格子把这个数记进锚点表就不再更新，
///     浮层从此稳定地偏掉半个条宽（实测 533.5 记成了 248.0）。
///
/// `NSView.convert(_:to:)` 没有这些毛病：它是当场算的，一次调用就是此刻的答案，
/// 与这个视图住在哪张 SwiftUI 图里、外面套了几层玻璃都无关。
///
/// **登记的是视图，不是数字。** 用的时候现问（见 `ZoneRegistry.frame(of:)`），
/// 所以不存在「记下来的那个数过期了」这回事——过期正是上面两次翻车的共同原因。
/// 不标 `@MainActor`：`BarModel` 本身不是主 actor 隔离的，而这本册子是它的一部分。
/// 内部碰 `NSView` 的地方一律 `assumeIsolated` —— 全部调用点（视图 body、事件分发）
/// 本来就在主线程上，真跑到别的线程去就当场断掉，不要让它悄悄读出一个错的几何。
final class ZoneRegistry {
    private var views: [String: ZoneView] = [:]

    fileprivate func add(_ view: ZoneView, id: String) {
        views[id] = view
    }

    /// **只撤自己那一份。** SwiftUI 会为同一格先建新视图、再拆旧视图（过渡期间两份并存），
    /// 旧的那份若无条件按 id 删，删掉的正是新的那一份刚登记好的——册子就此空掉，
    /// 症状是整条 bar 既不响应悬停、右键也只剩通用菜单。
    fileprivate func remove(_ view: ZoneView, id: String) {
        guard views[id] === view else { return }
        views.removeValue(forKey: id)
    }

    /// 这一项此刻在窗口坐标里的位置。视图已经离场就是 nil。
    func frame(of id: String) -> CGRect? {
        MainActor.assumeIsolated {
            guard let view = views[id], view.window != nil else { return nil }
            return view.convert(view.bounds, to: nil)
        }
    }

    func midX(of id: String) -> CGFloat? {
        frame(of: id)?.midX
    }

    /// 落点底下是哪一项。窗口坐标，当场算。
    func hit(_ point: CGPoint) -> String? {
        MainActor.assumeIsolated {
            views.first { _, view in
                view.window != nil && view.convert(view.bounds, to: nil).contains(point)
            }?.key
        }
    }

    /// 落空时把登记在册的区域一并记下来。只记落点说不出问题出在哪一侧——
    /// 是指针没落进去，还是这一项根本没登记上。
    var report: String {
        MainActor.assumeIsolated {
            guard !views.isEmpty else { return "一个都没登记" }
            return views.sorted { $0.key < $1.key }.map { id, view in
                guard view.window != nil else { return "\(id) 不在窗口里" }
                let rect = view.convert(view.bounds, to: nil)
                return String(format: "%@ x %.0f–%.0f y %.0f–%.0f",
                              id, rect.minX, rect.maxX, rect.minY, rect.maxY)
            }.joined(separator: "  ")
        }
    }
}

/// 登记用的空视图。画面上什么也不是，只是一块「这一项现在在这里」的实体。
final class ZoneView: NSView {
    fileprivate var id: String = ""
    fileprivate weak var registry: ZoneRegistry?

    /// **不接事件。** 命中判定由 `BarPanel` 与 `DropCatcher` 主动来问；
    /// 这里若接住了，SwiftUI 那边的悬停与点击就被截走了。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate func attach(to registry: ZoneRegistry, id: String) {
        guard self.registry !== registry || self.id != id else { return }
        self.registry?.remove(self, id: self.id)
        self.id = id
        self.registry = registry
        enroll()
    }

    fileprivate func detach() {
        registry?.remove(self, id: id)
        registry = nil
    }

    /// **进了窗口才算数。**
    ///
    /// `GlassRuler` 拿一个脱离视图树的 `NSHostingView` 去量内容（见 `DockGlass`），
    /// 那一份会把同样这些格子整套再建一遍——它不跑 `onAppear`、也不跑
    /// `onGeometryChange`，但**照样会实例化 NSViewRepresentable**。于是尺子那份
    /// 用同样的 id 把真正画出来的那份从册子里挤掉，册子里剩下的全是没有窗口的影子：
    /// 悬停问不到位置、右键一格都点不中，而没有任何东西会报错。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enroll()
    }

    private func enroll() {
        guard let registry else { return }
        if window == nil {
            registry.remove(self, id: id)
        } else {
            registry.add(self, id: id)
        }
    }
}

/// 把这一项登记进某本册子。垫在内容底下，不参与命中测试，也不占地方。
struct Zone: NSViewRepresentable {
    let id: String
    let registry: ZoneRegistry

    func makeNSView(context: Context) -> ZoneView {
        let view = ZoneView()
        view.attach(to: registry, id: id)
        return view
    }

    func updateNSView(_ view: ZoneView, context: Context) {
        view.attach(to: registry, id: id)
    }

    static func dismantleNSView(_ view: ZoneView, coordinator: ()) {
        MainActor.assumeIsolated { view.detach() }
    }
}

extension View {
    /// 把这一项登记为可命中的区域。位置到用的时候现问，见 `ZoneRegistry`。
    func zone(_ id: String, in registry: ZoneRegistry) -> some View {
        background { Zone(id: id, registry: registry).allowsHitTesting(false) }
    }
}
