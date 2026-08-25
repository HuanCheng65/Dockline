import Foundation

/// Claude Code 的 hook 适配（实时状态设计 §4.2）。
///
/// hook 把事件 JSON 送到 stdin，这里把它翻成一条上报。翻译放在 dockctl 而不是条那边：
/// 条只认自己那套状态模型，每接一个新的上报方就往里塞一份对方的事件表，模型迟早被
/// 上报方的形状带偏。
///
/// **不挂 `PermissionRequest`，改用 `Notification` 的 `permission_prompt`。** 前者是
/// 决策事件——hook 的返回值能左右这次授权准不准，而这里是个报状态的东西，不该有
/// 影响授权结果的机会，哪怕只是因为写错了。后者纯是通知。
enum HookAdapter {
    /// 摘要在胶囊上只占一行，长了会把胶囊拉成一条横幅。
    private static let summaryLimit = 40

    /// nil = 这个事件不表达任何状态，静默略过。
    ///
    /// 略过的是**认得但不表达**的那些（PreToolUse 落在别的工具上、限额自动续跑的几种
    /// 通知）。认不出来的事件根本到不了这里——settings.json 里只登记了下面这几个。
    static func payload(_ json: [String: Any]) -> [String: Any]? {
        switch json["hook_event_name"] as? String {
        case "SessionEnd":
            return ["command": "end"]

        // 用户提交了提示词，或某个工具刚跑完。后者同时负责把等待态撤下——
        // 授权批下来、问题答完之后，紧接着就是一次工具调用。
        case "UserPromptSubmit", "PostToolUse":
            return ["command": "push", "state": "working"]

        case "PreToolUse":
            switch json["tool_name"] as? String {
            case "ExitPlanMode": return waiting("plan")
            case "AskUserQuestion": return waiting("question")
            default: return nil
            }

        case "Notification":
            switch json["notification_type"] as? String {
            case "permission_prompt": return waiting("permission")
            case "idle_prompt", "agent_needs_input": return waiting("input")
            case "elicitation_dialog", "elicitation_url_dialog": return waiting("input")
            default: return nil
            }

        case "Stop":
            return finished("done", label: summary(json["last_assistant_message"]))

        case "StopFailure":
            return finished("failed", label: json["error_type"] as? String)

        default:
            return nil
        }
    }

    private static func waiting(_ reason: String) -> [String: Any] {
        ["command": "push", "state": "waiting", "reason": reason]
    }

    private static func finished(_ outcome: String, label: String?) -> [String: Any] {
        var payload: [String: Any] = ["command": "push", "state": "finished", "outcome": outcome]
        if let label { payload["label"] = label }
        return payload
    }

    /// 取回复的头一行做摘要。整段话里往往只有第一行是结论，后面是过程。
    private static func summary(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty
        else { return nil }
        guard line.count > summaryLimit else { return line }
        return line.prefix(summaryLimit - 1) + "…"
    }
}
