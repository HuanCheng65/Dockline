import Foundation

// dockctl —— 活动状态的上报入口（计划书 §3「活动状态」的自定义层）。
//
// 这个文件只做一件事：认动词，把参数交给对应的那一支。各支自己收在各自的文件里
// （`Push` / `Hook` / `HookInstaller`），通道与宿主推断在 `Report`。

let usage = """
用法：dockctl push  --state working|waiting [--reason question|permission|plan|input]
                    [--progress 0-1] [--label 文本] [--detail 文本] [共用选项]
      dockctl event --kind done|failed|quota [--label 摘要] [--detail 文本] [共用选项]
      dockctl end   [共用选项]
      dockctl hook  从 stdin 读 Claude Code 的 hook 事件 JSON，自行翻成上报
      dockctl install-hooks    把上一条登记进 ~/.claude/settings.json
      dockctl uninstall-hooks  撤销登记

共用选项：
  --session 标识   上报方的会话标识。同一个 App 里的多个会话靠它区分；
                   缺省时整个 App 共用一条，两个终端标签页会互相覆盖。
  --cwd 路径       用来推断这个会话住在哪扇窗口里。缺省取当前工作目录。
  --pid 进程号     宿主 App。缺省沿祖先进程链找到第一个 App。
  --window 窗口号  直接指定落在哪扇窗口上，跳过推断。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("dockctl: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
let rest = Array(arguments.dropFirst())

switch command {
case "push", "event", "end":
    Push.run(command, rest)
case "hook":
    Hook.run()
case "install-hooks", "uninstall-hooks":
    HookInstaller.run(command, rest)
default:
    fail(usage)
}
