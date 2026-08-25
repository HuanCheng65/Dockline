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
    /// 格子第二行与会话名只放得下一句。
    private static let summaryLimit = 40
    /// 终态面板贴出的那一段。够读出结论，又不至于把面板拉成一堵墙。
    private static let responseLimit = 600
    /// 命令全文。再长的命令，读完前两百个字符也判断得出它要干什么。
    private static let detailLimit = 200

    /// nil = 这个事件不表达任何状态，静默略过。
    ///
    /// 略过的是**认得但不表达**的那些（PreToolUse 落在别的工具上、限额自动续跑的几种
    /// 通知）。认不出来的事件根本到不了这里——settings.json 里只登记了下面这几个。
    static func payload(_ json: [String: Any]) -> [String: Any]? {
        switch json["hook_event_name"] as? String {
        case "SessionEnd":
            return ["command": "end"]

        // 提示词就是这条会话的名字。它只在这里出现一次，之后每个事件都不再带，
        // 由接收端粘住。
        // 新的一轮由此开始。接收端据此清掉上一轮的步子与结论——新提示词底下挂着
        // 上一轮的工具调用，读起来就像它正在做那件事。
        case "UserPromptSubmit":
            return ["command": "push", "state": "working", "turn": true]

        // 工具跑完了，模型在生成下一步。不带 tool，接收端显示「生成中」。
        // 它同时负责把等待态撤下：授权批下来、问题答完之后，紧接着就是一次工具调用。
        case "PostToolUse":
            return ["command": "push", "state": "working"]

        case "PreToolUse":
            switch json["tool_name"] as? String {
            case "ExitPlanMode": return waiting("plan")
            case "AskUserQuestion": return waiting("question")
            case let tool?:
                var payload: [String: Any] = ["command": "push", "state": "working",
                                              "tool": tool]
                if let object = object(json) { payload["object"] = object }
                if let detail = detail(json) { payload["detail"] = detail }
                if let metric = metric(json) { payload["metric"] = metric }
                return payload
            case nil:
                return nil
            }

        case "Notification":
            switch json["notification_type"] as? String {
            case "permission_prompt": return waiting("permission")
            case "idle_prompt", "agent_needs_input": return waiting("input")
            case "elicitation_dialog", "elicitation_url_dialog": return waiting("input")
            default: return nil
            }

        case "Stop":
            var payload = finished("done", label: summary(json["last_assistant_message"]))
            // 终态的面板贴的是这一段，不再列历史：那时要的是结论，不是经过。
            // 截断有上限，但比格子那一行宽得多——那一行只放得下一句。
            if let full = json["last_assistant_message"] as? String, !full.isEmpty {
                payload["response"] = String(full.prefix(responseLimit))
            }
            return payload

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

    /// 这条会话的名字，按可靠程度依次退让：
    ///
    /// 1. Claude Code 自己维护的会话标题。它比每轮都换的提示词稳，而格子第一行要的是身份
    /// 2. 用户这一轮的提示词摘要
    /// 3. 工作目录名——回答不了「哪件事」，但至少回答「哪个项目」
    ///
    /// 三样都没有就不带，接收端退回窗口标题。
    static func task(_ json: [String: Any]) -> String? {
        if let title = sessionTitle(json["transcript_path"] as? String) { return clamp(title) }
        if let prompt = summary(json["prompt"]) { return prompt }
        return (json["cwd"] as? String)
            .map { clamp(($0 as NSString).lastPathComponent) }
    }

    /// 会话标题在 transcript 的 `ai-title` 记录里，取最后一条。
    ///
    /// **必须从文件尾部倒着读。** transcript 会长到上百 MB（本机实测 117MB），整份读进来
    /// 是不可能的；倒着按块回扫，实测 0.3ms，便宜到每个事件都读一次也无所谓。
    /// 回扫有上限：找不到就是这个会话还没有标题，不值得为此把整份文件翻一遍。
    private static func sessionTitle(_ path: String?) -> String? {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var end = size
        for _ in 0..<scanChunks where end > 0 {
            let start = end > chunkSize ? end - chunkSize : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(end - start)) else { return nil }
            // 块边界会把一行切断，切断的那半解析不出来，跳过即可：`ai-title` 记录很密，
            // 丢掉最新的一条，拿到的也是同一个标题。
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      record["type"] as? String == "ai-title",
                      let title = record["aiTitle"] as? String, !title.isEmpty
                else { continue }
                return title
            }
            end = start
        }
        return nil
    }

    private static let chunkSize: UInt64 = 256 * 1024
    private static let scanChunks = 4

    /// 此刻这一步作用在什么上：文件名、命令里的程序名、检索式。
    ///
    /// **只送这一个词，不在这里拼句子。** 界面文案统一走条那边的本地化资源，
    /// 而 dockctl 不带资源包；让它拼好一句中文送过去，等于把界面文字散到条外面。
    /// 工具名原样送，动作怎么说由条决定。
    private static func object(_ json: [String: Any]) -> String? {
        let input = json["tool_input"] as? [String: Any] ?? [:]
        func path(_ key: String) -> String? {
            (input[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        let raw: String? = switch json["tool_name"] as? String {
        case "Read", "Edit", "NotebookEdit", "Write": path("file_path")
        case "Bash": command(input["command"] as? String)
        case "Grep", "Glob": input["pattern"] as? String
        case "WebFetch", "WebSearch": input["url"] as? String ?? input["query"] as? String
        case "Task", "Agent": input["description"] as? String
        default: nil
        }
        return raw.map(clamp)
    }

    /// 完整的那一份。当前那一行放得下它，历史行只放短的。
    ///
    /// 现在只有命令有：命令的全文是「它到底要跑什么」，缩成「git commit」之后那半句
    /// 恰恰是要判断的东西。文件路径不给——路径长而信息只在末段，面板已经显示末段了。
    private static func detail(_ json: [String: Any]) -> String? {
        guard json["tool_name"] as? String == "Bash",
              let command = (json["tool_input"] as? [String: Any])?["command"] as? String,
              !command.isEmpty
        else { return nil }
        return String(command.prefix(detailLimit))
    }

    /// 这一步的量化结果。改了多少、写了多少——一行动作后面缀一个数，
    /// 比只说「编辑了某文件」多回答一个问题：改得大不大。
    private static func metric(_ json: [String: Any]) -> String? {
        let input = json["tool_input"] as? [String: Any] ?? [:]
        func lines(_ key: String) -> Int? {
            (input[key] as? String).map { $0.isEmpty ? 0 : $0.components(separatedBy: "\n").count }
        }
        switch json["tool_name"] as? String {
        case "Edit", "NotebookEdit":
            // 一次替换就是「删掉旧的那几行、补上新的那几行」，这两个数正是它做的事
            guard let removed = lines("old_string"), let added = lines("new_string") else {
                return nil
            }
            return "+\(added) −\(removed)"
        case "Write":
            return lines("content").map { "+\($0)" }
        default:
            return nil
        }
    }

    /// 命令行里有信息的那一小段：程序名，加上紧随其后的子命令。
    ///
    /// 整条命令太长，占满一行也读不出重点；只取程序名又常常等于没说——`git`、`swift`、
    /// `npm` 本身不区分任何东西，`git commit` 与 `git log` 才是两件事。程序名取末段：
    /// 带路径调用时那条路径里唯一有信息的就是最后一节。子命令以 `-` 开头的不取，
    /// 那是选项不是子命令。
    private static func command(_ raw: String?) -> String? {
        let words = raw?.split(separator: " ").map(String.init) ?? []
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent })
        else { return nil }
        guard let next = words.dropFirst().first, !next.hasPrefix("-") else { return program }
        return "\(program) \(next)"
    }

    private static func clamp(_ text: String) -> String {
        text.count > summaryLimit ? text.prefix(summaryLimit - 1) + "…" : text
    }

    /// 取头一行做摘要。整段话里往往只有第一行是结论，后面是过程。
    private static func summary(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty
        else { return nil }
        return clamp(line)
    }
}
