import Foundation

/// Claude Code 的 hook 适配（实时状态设计 §4.2）。
///
/// hook 把事件 JSON 送到 stdin，这里把它翻成一条上报。翻译放在 dockctl 而不是条那边：
/// 条只认自己那套状态模型，每接一个新的上报方就往里塞一份对方的事件表，模型迟早被
/// 上报方的形状带偏。
///
/// `PermissionRequest` 不走这里，它有自己的一条路（见 `Ask` 与 `runAsk`）：它不是在报状态，
/// 是在替用户做一次决定。曾经因为「报状态的东西不该有影响授权结果的机会」而回避这个事件，
/// 就地授权推翻了那条顾虑，理由是**失败的形状**：这条路上的任何失败——条没在跑、连接断开、
/// 进程被超时杀掉——都表现为**不打印决定**，而不打印决定在 Claude Code 那边就是照常弹它自己
/// 的对话框。只有明确打印出来的那一个决定才算数，所以写错的后果止于退回现状。
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
    static func object(_ json: [String: Any]) -> String? {
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

    // MARK: 就地授权要看的那一段

    /// 面板上给出几行。多了就不再是「扫一眼决定批不批」，而是要读的东西——
    /// 那时候本来就该切回终端。
    private static let previewLines = 14
    /// 每行的宽度上限。面板只有那么宽，超出的部分在屏幕上根本落不下。
    private static let previewWidth = 200

    /// 这次授权要判断的内容，按行给出，每行带一个记号：`+` 增、`−` 删、空格是原文。
    ///
    /// **只送记号与文本，不在这里排版。** 怎么上色、怎么截断由条决定，
    /// 与工具名怎么翻成动词是同一条规矩。
    ///
    /// 返回的第二个数是截掉了多少行。条要把它说出来——一份被悄悄截短的 diff
    /// 会让人以为改动就这么点。
    static func preview(_ json: [String: Any]) -> (lines: [[String]], more: Int) {
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let raw: [[String]]
        switch json["tool_name"] as? String {
        case "Bash":
            raw = split(input["command"] as? String).map { [" ", $0] }
        case "Edit", "NotebookEdit":
            raw = diff(old: input["old_string"] as? String, new: input["new_string"] as? String)
        case "Write":
            raw = split(input["content"] as? String).map { ["+", $0] }
        // 这几样在标题行上已经说清了（读哪个文件、搜什么），再抄一遍是废话
        case "Read", "Grep", "Glob", "WebFetch", "WebSearch", "Task", "Agent":
            raw = []
        default:
            // 认不出的工具（MCP 一类）：把参数原样摆出来。判断不了它要干什么的时候，
            // 至少要让人看得见它拿到了什么。
            let data = try? JSONSerialization.data(withJSONObject: input,
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes])
            raw = split(data.flatMap { String(data: $0, encoding: .utf8) }).map { [" ", $0] }
        }
        let kept = raw.prefix(previewLines).map { [$0[0], String($0[1].prefix(previewWidth))] }
        return (Array(kept), raw.count - kept.count)
    }

    private static func split(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// 一次替换真正动了哪几行。
    ///
    /// 逐行求最长公共子序列，**只列不同的那些**，相同的行一概不列。两条理由：
    ///
    ///   · 只掐掉两头相同的行是不够的。一次替换里常常夹着没动的行——改一个块里的
    ///     某一行是最典型的形状——那些行会被同时列成删和增，也就是在说「这一行动过」，
    ///     而它没动。面板是拿来下判断的，不能说一件没发生的事。
    ///   · 相同的行作上下文也不列。面板只放得下十几行，用来摆没动的行，
    ///     真正改了的那几行就被挤出去了。
    ///
    /// 行数有上界：最长公共子序列是二次的。超过就退回只掐两头——那样的改动本来就不该
    /// 在条上判，该切回终端看。
    private static let diffLimit = 400

    private static func diff(old: String?, new: String?) -> [[String]] {
        let before = split(old)
        let after = split(new)
        guard before.count <= diffLimit, after.count <= diffLimit else {
            var head = 0
            while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
            var tail = 0
            while tail < before.count - head, tail < after.count - head,
                  before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
            return before[head..<(before.count - tail)].map { ["−", $0] }
                + after[head..<(after.count - tail)].map { ["+", $0] }
        }
        // lengths[i][j] = before 的第 i 行起、after 的第 j 行起，两者最长公共子序列的长度
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: after.count + 1),
                              count: before.count + 1)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i][j] = before[i] == after[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var result: [[String]] = []
        var i = 0
        var j = 0
        while i < before.count, j < after.count {
            if before[i] == after[j] {
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(["−", before[i]])
                i += 1
            } else {
                result.append(["+", after[j]])
                j += 1
            }
        }
        return result + before[i...].map { ["−", $0] } + after[j...].map { ["+", $0] }
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
