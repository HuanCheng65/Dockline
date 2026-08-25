import AppKit
import DocklineCore
import SwiftUI

/// 分屏的落点预览（计划书 §3「接管最大化」）。
///
/// 拖着窗口格往上一提，格子就长成它将要占据的那半块屏。这块玻璃因此不是第四种弹出面板——
/// 它画在桌面上、报的是一个落点，借的是系统拼贴那套语言，而不是条上方那块浮层的语言。
///
/// 松手时的动效也由它承担：它此刻正停在窗口要去的那个矩形上，所以先把几何写下去、
/// 再让它化开，窗口在它底下就位，读起来就是「预览变成了窗口」。我们改不动别人窗口的
/// 动画，AX 写下去就是一跳，这是唯一能把那一跳盖住的办法。
final class SplitPreview {
    /// 长出来与滑到另一半共用这条曲线。
    private static let travel = Animation.spring(response: 0.3, dampingFraction: 0.82)
    /// 化开的时长。窗口已经就位，这一段只是把接缝盖住，不该让人等。
    private static let dissolve: TimeInterval = 0.18
    /// 收回去的时长（取消时）。
    private static let retract: TimeInterval = 0.22

    private let state = State()
    private var panel: NSPanel?
    /// 从哪一格长出来的。取消时要缩回同一个地方。
    private var origin: CGRect = .zero
    private var closing: DispatchWorkItem?

    /// 摆到某个落点上。第一次调用时从 `origin` 长出来，之后是同一块玻璃滑过去。
    func aim(at rect: CGRect, on screen: NSScreen,
             from cell: CGRect, icon: NSImage?, title: String) {
        closing?.cancel()
        closing = nil
        let panel = panel(on: screen)
        let goal = local(rect, in: screen)
        guard state.opacity == 0 else {
            guard state.rect != goal else { return }
            withAnimation(Self.travel) { state.rect = goal }
            return
        }
        origin = cell
        state.icon = icon
        state.title = title
        state.rect = local(cell, in: screen)
        state.opacity = 1
        panel.orderFront(nil)
        // 起点必须先上一帧屏。同一次事务里把尺寸连改两次，SwiftUI 只看得到终点，
        // 于是没有可插值的起点——长出来的动画就只剩淡入（浮层那三档踩过同一个坑，
        // 见计划书 §3.1）。
        DispatchQueue.main.async { [weak self] in
            guard let self, state.opacity > 0 else { return }
            withAnimation(Self.travel) { self.state.rect = goal }
        }
    }

    /// 窗口已经贴过去了，把预览化开。
    func dissolve() {
        guard state.opacity > 0 else { return }
        withAnimation(.easeOut(duration: Self.dissolve)) { state.opacity = 0 }
        close(after: Self.dissolve)
    }

    /// 用户放弃了，缩回它长出来的那一格。
    func cancel() {
        guard state.opacity > 0, let panel, let screen = panel.screen else { return }
        withAnimation(.easeOut(duration: Self.retract)) {
            state.rect = local(origin, in: screen)
            state.opacity = 0
        }
        close(after: Self.retract)
    }

    var isAiming: Bool { state.opacity > 0 && closing == nil }

    private func close(after delay: TimeInterval) {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.closing = nil
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 屏幕坐标（AppKit，左下原点）→ 面板内的 SwiftUI 坐标（左上原点）。
    private func local(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX,
               y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    /// 面板铺满目标屏。落点是屏幕级的量，画在一块屏幕大小的板子上最省事，
    /// 也不必在换边时搬动窗口。
    private func panel(on screen: NSScreen) -> NSPanel {
        if let panel, panel.frame == screen.frame { return panel }
        let panel = self.panel ?? make()
        panel.setFrame(screen.frame, display: false)
        self.panel = panel
        return panel
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // 拖拽正在进行，这块板子绝不能接事件：它铺满整块屏，接了就把手势整个吃掉。
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: SplitGhost(state: state))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    final class State: ObservableObject {
        @Published var rect: CGRect = .zero
        @Published var opacity: Double = 0
        @Published var icon: NSImage?
        @Published var title = ""
    }
}

/// 落点那块玻璃。
private struct SplitGhost: View {
    @ObservedObject var state: SplitPreview.State

    /// 系统窗口的圆角。落点画的是「窗口将会在这儿」，圆角就该是窗口的圆角。
    private static let radius: CGFloat = 12
    /// 图标不跟着放大：长出来的是容器，不是图标。
    private static let iconSize: CGFloat = 64

    var body: some View {
        // 分支一律不出现在带 `.frame` 的这一层（计划书 §3.1）：换了 identity 的视图
        // 拿不到尺寸的起点，长出来的动画就只剩淡入。
        ZStack(alignment: .topLeading) {
            Color.clear
            card
                .frame(width: state.rect.width, height: state.rect.height)
                .offset(x: state.rect.minX, y: state.rect.minY)
                .opacity(state.opacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return shape
            .fill(.regularMaterial)
            .overlay {
                VStack(spacing: 10) {
                    if let icon = state.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: Self.iconSize, height: Self.iconSize)
                    }
                    Text(state.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                }
            }
            .overlay {
                shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            // 起点是条上那一格，比图标还小；不裁掉的话，长出来的头几帧图标会挂在框外面。
            .clipShape(shape)
    }
}
