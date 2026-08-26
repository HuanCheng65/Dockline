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
