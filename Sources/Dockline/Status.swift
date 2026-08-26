import AppKit
import DocklineCore
import SwiftUI

/// 活动挂在条上的哪一格。
///
/// 上报方给不出这个答案：它知道自己的 cwd 与祖先进程，不知道自己住在哪扇窗口里。
/// 由 `SessionBinding` 从这两样推断，推不出来就退回 `.app`——那是 App 在条上的第一格，
/// 与未读角标同一条规则。
enum StatusTarget: Hashable {
    case app(pid_t)
    case window(CGWindowID)
}

/// 一格上此刻显示的状态。
///
/// **两种并列，不是一种的两档。** 分界不是复杂度，是种类：
///
///   · **任务型**（会话）有生命周期——在跑、等你、停了——因而**可以**要你的注意力。
///   · **常驻型**（播放）没有生命周期，不会结束，也**永远不该**要你的注意力。
///
/// 这条界线解释了为什么播放不能做成第四档 `Session.Salience`：那三档整个建立在
/// 「此刻谁在等谁」上，而播放对这个问题的回答是「没人在等谁」。塞进去等于让一件不参与
/// 注意力竞争的事排进注意力队列，而注意力路由正是这整条产品线的本职。
///
/// 格子那一层只认这个类型，不认它里面是什么（见下面那几个属性）。面板反过来各写各的：
/// 一条时间线和一个播放器没有一处能共用，硬套一个模板只会得到两边都不称职的一张卡。
enum CellStatus: Equatable {
    case session(Session)
    case media(NowPlaying)

    /// 格子上那两行：第一行是这是什么，第二行是此刻怎样。
    ///
    /// 两种状态在这里合流，也只在这里合流——**这就是那道缝**。
    var lines: (first: String?, second: String?) {
        switch self {
        case .session(let session):
            return (session.task, session.stateLine)
        case .media(let playing):
            return (playing.line, playing.subline)
        }
    }

    /// 点缀层的进度环。nil = 不画环。
    var progress: Double? {
        switch self {
        // 播放进度不上格子。它一秒变一次，而条上会动的东西是要克制的；
        // 要看到哪儿了，面板里有一条细线。
        case .media: return nil
        case .session(let session): return session.progress
        }
    }

    /// 显著度。**播放没有**——它不参与这套排序，这正是上面那条界线的意思。
    var salience: Session.Salience? {
        switch self {
        case .session(let session): return session.salience
        case .media: return nil
        }
    }

    /// 终态那一档要用户看过才退场。播放没有终态，也就没有「看过」这回事。
    var isUnread: Bool {
        switch self {
        case .session(let session): return session.isUnread
        case .media: return false
        }
    }

    var session: Session? {
        if case .session(let session) = self { return session }
        return nil
    }

    var media: NowPlaying? {
        if case .media(let playing) = self { return playing }
        return nil
    }
}
