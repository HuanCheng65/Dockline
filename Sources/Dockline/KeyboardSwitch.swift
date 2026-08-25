import AppKit
import Carbon.HIToolbox
import DocklineCore

/// 窗口级键盘切换（计划书 §6 M6）。
///
/// 按住 ⌥ 起一次会话：Tab 按最近使用顺序推进、⇧Tab 反向，方向键按条上的排布左右移动，
/// 松开 ⌥ 确认。原则是 **Tab 用时间记忆，方向键用空间记忆**——两套顺序各自成立，
/// 混着按也讲得通：当前选中的是哪个窗口是唯一的会话状态，两套顺序只是移动的方式。
///
/// 这是本项目唯一一处**拦截式** event tap（`FullscreenWatch` 那支只观察不吞）。可行性
/// 已由 `docklinespike keytap` 实测，读数与约束记在计划书 §6 M6，其中三条直接决定了
/// 下面的写法：抬起按配对状态吞、自动重复不推进选择、停用后重读修饰键而不信边沿。
final class KeyboardSwitch {
    private static let tabKey = Int64(kVK_Tab)
    private static let leftKey = Int64(kVK_LeftArrow)
    private static let rightKey = Int64(kVK_RightArrow)
    private static let escapeKey = Int64(kVK_Escape)
    private static let spaceKey = Int64(kVK_Space)

    /// 会话开始到显形之间的沉默期。飞快按一下 ⌥Tab 换到上一个窗口是最高频的用法，
    /// 那一下全程不该有任何东西闪，系统的 ⌘Tab 同样如此。§9 的待调参项。
    private static let revealDelay: TimeInterval = 0.18

    private weak var world: World?
    private var tap: CFMachPort?
    private var reveal: DispatchWorkItem?

    /// 按下时吞掉了哪些键。抬起照着这份名单吞，不看修饰键——快切的常见次序是
    /// 按 ⌥Tab、先松 ⌥ 确认、再松 Tab，最后那条 Tab 抬起身上已经没有 ⌥ 了，
    /// 按修饰键判会漏给前台 App 一条没有配对按下的抬起。
    private var swallowed: Set<Int64> = []

    private var session: Session?

    /// 一次会话。
    ///
    /// 冻住的只有时间序的**名次**——期间若让它跟着前台变化重排，同一个方向连按两次
    /// 会走到不同的地方。名单不冻：会话开始后才进索引的窗口（新建的窗口尤其，它进索引
    /// 要等 AX 通知）必须能被走到，否则用户刚开的那个窗口整场都够不着。
    /// 空间序是条上的排布，本来就不随前台变化，每次现算即可。
    private struct Session {
        var selected: CGWindowID
        let clock: [CGWindowID: Int]
    }

    init(world: World) {
        self.world = world
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardSwitch>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Timeline.log("⚠️ 键盘切换不可用：拦截式 event tap 创建失败"
                         + "（辅助功能权限 = \(AXIsProcessTrusted())）")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: 事件

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .keyDown:
            return keyDown(event) ? nil : pass

        case .keyUp:
            // 抬起不看修饰键，只看按下时吞没吞
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard swallowed.contains(code) else { return pass }
            swallowed.remove(code)
            if code == Self.spaceKey { endPeek() }
            return nil

        case .flagsChanged:
            if session != nil, !event.flags.contains(.maskAlternate) { confirm() }
            return pass

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            guard let tap else { return nil }
            CGEvent.tapEnable(tap: tap, enable: true)
            Timeline.log("键盘切换的 event tap 被系统停用，已重新启用")
            // 停用期间的抬起也丢了。名单不清空的话，那个键会一直挂在上面，
            // 下一次正常按它时抬起被吞——前台 App 收到一条没有配对抬起的按下，
            // 正是这份名单要防的事情反过来发生一遍。
            swallowed.removeAll()
            // 空格的抬起同样可能丢在里面，而大预览是按着才成立的：收不到抬起就散掉，
            // 不能让它一直开着。
            endPeek()
            // 停用期间的事件是彻底收不到的，⌥ 的松开边沿可能就丢在里面。
            // 修饰键状态因此不能只靠边沿维护，重新启用后直接读一次当前状态。
            if session != nil,
               !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
                confirm()
            }
            return nil

        default:
            return pass
        }
    }

    /// 返回 true 表示这一条由我们吞掉。
    private func keyDown(_ event: CGEvent) -> Bool {
        let flags = event.flags
        // 只认单独的 ⌥（⇧ 是反向，允许）。⌘⌥Tab、⌃⌥Tab 之类是别人的组合键，
        // 不加这一道就会被我们连窝端走。
        let plainOption = flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)

        guard session != nil else {
            // 快路径。会话之外只有两件事会发生：干净的 ⌥Tab 起一次会话，
            // 以及预览卡开着时干净的空格放大它。绝大多数击键在这几行就走人
            // ——这段代码挂在每一次击键上，所以先比键码再看别的。
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.spaceKey {
                // 组合键里的空格是别人的（⌃空格切输入法、⌘空格聚焦），一律不碰
                guard flags.isDisjoint(with: [.maskAlternate, .maskCommand,
                                              .maskControl, .maskShift]) else { return false }
                // 长按会自动重复，照吞不误——放行的话前台 App 会收到一串空格
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                    return swallowed.contains(Self.spaceKey)
                }
                guard beginPeek() else { return false }
                swallowed.insert(Self.spaceKey)
                return true
            }
            guard plainOption, code == Self.tabKey else { return false }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return swallowed.contains(Self.tabKey)
            }
            guard begin(reverse: flags.contains(.maskShift)) else { return false }
            swallowed.insert(Self.tabKey)
            return true
        }

        // 会话中是一个模式。模式里的每一个按键都要有明确归属，没有归属的就退出这个模式——
        // 悬着不管的话，用户去做了别的事，最后那次松开 ⌥ 仍然会把窗口切走。
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == Self.escapeKey {
            cancel()
            // 抬起要配对，否则前台 App 会收到一条没有按下的 Esc 抬起
            swallowed.insert(code)
            return true
        }
        guard plainOption else {
            cancel()
            return false
        }
        // 空格在会话里也是放大，不是「不属于这个模式的键」。不认它的话，会话中想看清
        // 选中的到底是哪个窗口，按下去会既散掉会话、又给前台 App 打进一个空格。
        if code == Self.spaceKey {
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                return swallowed.contains(code)
            }
            guard beginPeek() else {
                cancel()
                return false
            }
            swallowed.insert(code)
            return true
        }
        switch code {
        case Self.tabKey, Self.leftKey, Self.rightKey:
            break
        default:
            cancel()
            return false
        }
        // 自动重复照吞，但不推进选择。实测重复率约每秒十余次、且随用户在系统设置里的
        // 按键重复速率变化，逐次推进会快到看不清，浮层的展开动画也跟不上。
        // 吞是必须的：放行的话长按会把一串 Tab 漏给前台 App。
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            if code == Self.tabKey {
                step(byRecency: true, forward: !flags.contains(.maskShift))
            } else {
                step(byRecency: false, forward: code == Self.rightKey)
            }
        }
        swallowed.insert(code)
        return true
    }

    // MARK: 会话

    /// 起一次会话并落下第一个选择。窗口不足两个时不起——那时 ⌥Tab 没有可去之处，
    /// 交回系统比吞掉它更诚实。
    private func begin(reverse: Bool) -> Bool {
        guard let world else { return false }
        let clock = world.lastActive
        let recency = world.recencyOrder(clock: clock)
        guard recency.count >= 2 else { return false }
        watchMouse()
        for bar in world.bars { bar.setKeySession(true) }
        let work = DispatchWorkItem { [weak self] in
            self?.reveal = nil
            guard let world = self?.world, self?.session != nil else { return }
            for bar in world.bars { bar.setKeyVisible(true) }
        }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: work)

        if let front = world.frontWindow, recency.contains(where: { $0.id == front }) {
            session = Session(selected: front, clock: clock)
            // 首次触发直接落在上一个实际聚焦过的窗口上
            step(byRecency: true, forward: !reverse)
        } else {
            // 前台窗口还不在索引里——刚新建的窗口正是这一类，它进索引要等 AX 通知。
            // 此时第一次就落在最近用过的那个；那个新窗口随后进索引，本次会话照样走得到。
            session = Session(selected: recency[0].id, clock: clock)
            publish()
        }
        return true
    }

    /// 两条序列都现算。名次由会话开始时冻结的那份活跃序号定，成员跟着索引走。
    private func order(byRecency: Bool) -> [IndexedWindow] {
        guard let world, let session else { return [] }
        return byRecency ? world.recencyOrder(clock: session.clock) : world.spatialOrder
    }

    private func step(byRecency: Bool, forward: Bool) {
        guard var session else { return }
        let list = order(byRecency: byRecency)
        guard !list.isEmpty else { return }
        let next: Int
        if let current = list.firstIndex(where: { $0.id == session.selected }) {
            next = (current + (forward ? 1 : -1) + list.count) % list.count
        } else {
            // 选中的窗口不在这条序列里：它可能刚被关掉，也可能压根没落在任何一条 bar 上
            // （空间序只收条上有格子的窗口）。从这一端重新起步，而不是原地不动。
            next = forward ? 0 : list.count - 1
        }
        session.selected = list[next].id
        self.session = session
        publish()
    }

    // MARK: 大预览（计划书 §6 M6）
    //
    // 预览卡已经长出来时按住空格把它放大，松开收回——快速查看那一套。悬停与键盘会话
    // 是同一个动作：⌥Tab 会话里 ⌥ 已经被占着，再让修饰键兼职就冲突了，空格两边通用。
    //
    // **只在有卡可放大时吞这个键。** 没有卡的空格就是普通的空格，原样交回去；
    // 指针恰好停在条上、人却在打字，是完全正常的事。

    /// 返回 true 表示这一下由我们吞掉。
    private func beginPeek() -> Bool {
        guard let world, let bar = world.bars.first(where: { $0.peekTarget != nil })
        else { return false }
        // 长高面板、重排浮层要出这个回调再做：回调里做慢活，系统会因超时把整个 tap 停用
        DispatchQueue.main.async { bar.setPeeking(true) }
        return true
    }

    private func endPeek() {
        guard let world else { return }
        DispatchQueue.main.async { for bar in world.bars { bar.setPeeking(false) } }
    }

    // MARK: 会话期间的鼠标
    //
    // 用户中途伸手去点了某个窗口，那个窗口就是他要的；此时再让最后那次松开 ⌥ 把选中项
    // 唤起来，等于把他刚点的顶掉。按下鼠标即放弃这次切换。
    //
    // 用 NSEvent 监听而不是把鼠标事件并进那个拦截式 tap：拦截式 tap 会把事件的投递
    // 挡在我们的回调后面，而这个回调与 SwiftUI 的渲染共用主线程——为一个每天只活跃
    // 几秒的功能，让全系统的点击排在我们的帧后面，代价不成比例。这里也不需要消费点击，
    // 只需要知道它发生了。

    private var mouseWatch: [Any] = []

    private func watchMouse() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // 全局那条听不到落在自己身上的点击，点条上的格子要靠本地这条
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: {
            [weak self] _ in self?.cancel()
        }) {
            mouseWatch.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: {
            [weak self] event in self?.cancel(); return event
        }) {
            mouseWatch.append(local)
        }
    }

    private func releaseMouseWatch() {
        for monitor in mouseWatch { NSEvent.removeMonitor(monitor) }
        mouseWatch.removeAll()
    }

    private func publish() {
        guard let world, let session else { return }
        // 每条 bar 都收到同一个选择，拥有那个窗口的那条才画得出来
        for bar in world.bars { bar.setKeySelection(session.selected) }
    }

    /// 放弃这次切换：把借来的东西还回去，不动任何窗口。
    /// 出口有三条——Esc、会话中按下鼠标、会话中按了不属于这个模式的键。
    private func cancel() {
        guard let world, session != nil else { return }
        session = nil
        reveal?.cancel()
        reveal = nil
        releaseMouseWatch()
        for bar in world.bars { bar.setKeySession(false) }
    }

    private func confirm() {
        guard let world, let session else { return }
        self.session = nil
        // 还没显形就确认了：这是快按快松那一下，视觉上自始至终什么也没发生过
        reveal?.cancel()
        reveal = nil
        releaseMouseWatch()
        // `swallowed` 不在这里清：⌥ 通常先于 Tab 松开，那条 Tab 抬起还得照吞
        for bar in world.bars { bar.setKeySession(false) }
        // 兜了一圈回到原处：什么也没发生，就什么也不做。对当前前台再唤起一次是白费，
        // 而且窗口在别的 Space 上时那一次唤起会真的把 Space 切过去。
        guard session.selected != world.frontWindow else { return }
        guard let window = world.windows.first(where: { $0.id == session.selected }) else {
            Timeline.log("⚠️ 键盘切换：选中的 wid \(session.selected) 确认时已不在索引里")
            return
        }
        // 唤起要出这个回调再做。召回走 AX，是跨进程调用，慢的那一下能拖到几百毫秒；
        // 在事件回调里做，系统会因回调超时把整个 tap 停用（`FullscreenWatch` 里
        // 对 AX 命中测试记着同一条）。回调返回后主队列立刻就轮到它。
        DispatchQueue.main.async { [weak world] in
            guard let world else { return }
            world.recall(window)
            // 谁在前台是我们刚刚亲自决定的，直接记账，不等 AX 通知绕回来
            world.noteActivated(window.id)
        }
    }
}
