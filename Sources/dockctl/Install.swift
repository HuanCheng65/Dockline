import Foundation

/// 把 hook 登记进 Claude Code 的用户级设置（实时状态设计 §4.1）。
///
/// 三条自我约束，因为这是别人的全局配置：
///   · 解析不了就**原样不动**并报错。settings.json 若被写成 JSON 之外的东西（注释一类），
///     覆盖写回等于替用户重写他的配置。
///   · 写之前留一份带时间戳的备份。
///   · 可撤销，且重复安装不会堆积——每次先摘掉自己上次留下的条目再装。
enum HookInstaller {
    /// 要登记哪些事件。matcher 为 nil 表示这个事件全收，具体认哪几种由 `HookAdapter` 判。
    ///
    /// `Notification` 不加 matcher：它的取值另有一套（`notification_type`），
    /// 写错了的后果是 hook 永远不触发，而这种失败是哑的。放在适配那边判，看得见。
    private static let events: [(event: String, matcher: String?)] = [
        ("UserPromptSubmit", nil),
        ("PostToolUse", nil),
        // 全部工具都收：格子第二行要说清此刻在做什么，而那正是每次工具调用带来的。
        // 只收 ExitPlanMode / AskUserQuestion 的话，在跑的那一档就只剩「生成中」。
        ("PreToolUse", nil),
        ("Notification", nil),
        // 就地授权。**这一条是阻塞的**：它停在那里等条上的回答，期间 Claude Code
        // 停在这一步不动。不给它设更短的超时——那等于替用户定「多久算不管了」，
        // 而 Claude Code 自己那道超时（command 型 hook 默认 600 秒）到点之后
        // 丢掉本条的输出、照常弹它自己的对话框，什么都不会丢。
        ("PermissionRequest", nil),
        ("Stop", nil),
        ("StopFailure", nil),
        ("SessionEnd", nil),
    ]

    /// 默认写用户级设置。`--settings` 能改写目标，那不是给日常用的，是为了**能测**：
    /// `NSHomeDirectory()` 不认环境变量 `HOME`，换个假的主目录跑一遍这条路根本骗不过它，
    /// 于是「合并会不会碰坏别人已有的 hook」这件事就只能拿真配置去试——那是不能接受的。
    private static func settingsURL(_ override: String?) -> URL {
        guard let override else {
            return URL(fileURLWithPath: ("~/.claude/settings.json" as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }

    /// 自己的绝对路径。装进配置里的就是这一份——换了位置要重装，这一点在提示里说明。
    private static var executable: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments[0]
    }

    private static var command: String { "'\(executable)' hook" }

    /// 认自己留下的条目：命令行里带着 dockctl。
    private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains("dockctl") == true
    }

    static func run(uninstall: Bool, settings: String? = nil) -> String {
        let url = settingsURL(settings)
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else {
                fail("读不了 \(url.path)")
            }
            guard let parsed = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else {
                fail("\(url.path) 不是一个 JSON 对象，没有改动它。"
                     + "若里面有注释一类的非标准写法，请先手工登记 hook。")
            }
            root = parsed
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.dockline-\(stamp).bak")
            guard (try? data.write(to: backup)) != nil else {
                fail("备份写不进 \(backup.path)，没有改动原文件")
            }
        } else if uninstall {
            return "\(url.path) 不存在，无需撤销。"
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var removed = 0
        var added = 0

        // 先把自己上次留下的条目全摘掉：重复安装才不会堆积，撤销也走同一段。
        for (event, raw) in hooks {
            guard var groups = raw as? [[String: Any]] else { continue }
            for index in groups.indices {
                guard var list = groups[index]["hooks"] as? [[String: Any]] else { continue }
                let before = list.count
                list.removeAll(where: isOurs)
                removed += before - list.count
                groups[index]["hooks"] = list
            }
            // 摘空了的组连同事件一起收掉，别在配置里留下空壳
            groups.removeAll { ($0["hooks"] as? [[String: Any]])?.isEmpty ?? true }
            hooks[event] = groups.isEmpty ? nil : groups
        }

        if !uninstall {
            for (event, matcher) in events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                var group: [String: Any] = ["hooks": [["type": "command", "command": command]]]
                if let matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[event] = groups
                added += 1
            }
        }

        root["hooks"] = hooks.isEmpty ? nil : hooks
        guard let out = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            fail("生成 JSON 失败，没有改动原文件")
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? out.write(to: url)) != nil else { fail("写不进 \(url.path)") }

        let verb = uninstall ? "撤销" : "安装"
        return """
            \(verb)完成：\(url.path)
              摘掉旧条目 \(removed) 条，写入 \(added) 条
              命令：\(command)
            原文件已备份在同一目录下的 settings.json.dockline-*.bak。
            注意：写回时整个文件按标准 JSON 重排了缩进与键序。
            dockctl 换了位置之后要重新执行一次安装。
            """
    }
}
