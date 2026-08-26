/// 上报里那个动作词（实时状态设计 §4.2）。
///
/// **这是一套共用词汇，不是某一个 agent 的工具表。** 先前送的是 Claude Code 的工具原名
/// （`Read`、`Bash`），条那边拿它当本地化的键——等于把一个上报方的工具表焊进了界面文案：
/// 再接一个 agent，同一件「读文件」就要在资源里躺两份键，而且资源会随上报方的数量增长。
///
/// 翻译因此留在各自的适配器里（见 `HookAdapter.verb`），过线的只有下面这几个词。
///
/// **认不出的工具原样送它的名字**，不归一成「其他」一类的说法：条那边找不到对应文案就
/// 直接显示这个名字，而工具原名至少是真的——泛化的说法把「这一步在干什么」这个唯一
/// 要答的问题答成了废话。
enum Verb: String {
    case read
    case edit
    case write
    /// 跑一条命令
    case run
    /// 在本机找东西
    case search
    /// 取一个网页
    case fetch
    case websearch
    /// 派一个子 agent 去做
    case subtask
    case todo
}
