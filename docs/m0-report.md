# M0 · 命令行 spike 验收报告

2026-08-23 · macOS 26.5.2 (25F84) · Swift 6.3.1 / Xcode 26.4.1 · MacBook Air (Built-in Retina Display 1470×840 visibleFrame)

对应计划书第 6 节 M0：「在真实机器上，枚举完整、召回成功率与盲区范围量化清楚。」

**结论：枚举与盲区已完全量化，五条召回路径全部通过，无需在计划书既定的私有符号清单之外新增任何符号。技术风险清零，可进 M1。**

---

## 1. 交付物

`Sources/moorspike/`，451 行 Swift，无 UI：

| 文件 | 职责 |
|---|---|
| `Private.swift` | 私有符号唯一封装点。第 0 层 `_AXUIElementGetWindow` 静态链接；第 1 层 SkyLight 走 `dlsym`，带启动自检与整族降级 |
| `WindowIndex.swift` | 通道一（AX 枚举 + 每 App 健康度探针）、通道三（CGWindowList 对账） |
| `main.swift` | `list` / `raise <wid>` / `fill <wid>` / `hold-raise <wid>` / `activate <pid>` / `roundtrip <pid> [wid]` |

用到的私有符号：`_AXUIElementGetWindow`（第 0 层）、`SLSMainConnectionID` / `SLSGetActiveSpace` / `SLSCopySpacesForWindows` / `SLSWindowIsOrderedIn`（第 1 层只读）。全部集中在 `Private.swift`，无一逸出。

---

## 2. 最重要的发现：AX 通道的边界

**`kAXWindowsAttribute` 只返回「当前 Space 上的窗口」+「最小化的窗口」。**

受控 A/B 证据（同一台机器，仅切换 Space）：

| App | 在 Space 3 时 AX 窗口数 | 切到 Space 456 后 |
|---|---|---|
| Code | 1 | **0** |
| Ghostty | 1 | **0** |
| 微信 | 1 | **0** |
| Arc | **0** | 2 |
| QQ（窗口最小化） | 1 | **1**（不变） |

切换 Space 后消失的那些窗口，随即出现在 CG 对账的盲区列表里，且 `Space` 值正确指回原 Space。

两个直接推论：

- **最小化窗口跨 Space 始终留在 AX 里。** 这是 bar 的置灰行为和时光机的承重点——最小化的窗口永远拿得到 AX 引用和标题，不需要任何兜底。
- **其他 Space 上的非最小化窗口没有 AX 引用**，因而**读不到标题**（标题坚持只走 AX，不碰 `kCGWindowName`，后者需屏幕录制权限）。这是 M1 必须正面处理的设计问题，见第 6 节。

这不是缺陷，是计划书 §4「无 AX 引用的存量窗口走激活 App 粗路」预算好的约束，按时出现。

---

## 3. 盲区量化

CG 候选窗口口径：layer 0 · alpha > 0.05 · 尺寸 ≥ 60² · 排除自身进程。

```
CG 候选                       61
  ├─ 被 AX 覆盖                3      （当前 Space 的窗口 + 最小化窗口）
  └─ AX 盲区                  58
       ├─ <300² 噪声           26     光标服务、自动填充助手、各类 64×64 系统 surface
       ├─ ordered-out 僵尸     29     ★ 见下
       └─ ordered-in 真窗口     3     Arc(Space 456,全屏) / Ghostty(477) / 微信(477)
```

**真盲区只有 3 个，且全部是「在别的 Space 上」这一个已知原因**，全部可经 `activate` 路径召回（见第 4 节）。

### 3.1 判别式：ordered-in，不是 Space 归属

第一版判别式用「是否有 Space 归属」，**错误**。经用户实机核对否决：Clash Verge / OrbStack / Thaw / Longshot 被判为真窗口，但它们实际上一个窗口都没开。

原因：这类 App（Tauri 系、菜单栏 App）关闭窗口时不销毁 `NSWindow`，只做 `orderOut:`。窗口对象仍然活着、仍然挂在原 Space 上，因此照样查得到 Space 归属。

正确判别式是 **`SLSWindowIsOrderedIn`**（⚠️ 有一个例外，见第 8 节：**最小化窗口也是 ordered-out**，须由 AX 通道认领）：被 `orderOut:` 关掉的窗口是 ordered-out；而位于其他 Space 的真窗口依然 ordered-in。

换用后 29 个僵尸 surface 全部正确剔除，与用户实机认知完全一致：

| App | 僵尸 surface | 说明 |
|---|---|---|
| Clash Verge | 4（含 1470×840、888×645×2） | 用户确认无窗口 |
| OrbStack | 4（含 975×649） | 用户确认无窗口 |
| Bitwarden | 2（含 1470×840） | 无窗口 |
| Thaw | 2 | 用户确认不应算真窗口 |
| Longshot | 1（900×628） | 用户确认不应算真窗口 |
| Ghostty | 4（重复 800×632 ×3 + 500×500 空壳） | 同一 App 的历史 surface |
| 微信 | 6（pid 2382 下 4 个 + pid 8921 下 2 个） | 小程序宿主 surface |
| QQ | 2（800×600 / 720×640） | |
| Code / Raycast / loginwindow / 自动填充 | 各 1 | 均为 500×500 空壳（自动填充除外） |

`500×500` 是一个反复出现的模式（Code / Bitwarden / Clash Verge / Ghostty / OrbStack / Raycast / loginwindow 都有），是从未 order-in 过的 `NSWindow` 默认尺寸空壳。ordered-in 判别式对它们 100% 命中。

### 3.2 alpha 无判别力

全部 32 个 ≥300² 盲区窗口 alpha 均为 1.00（唯一例外微信 0.98）。alpha 不能用于区分。

---

## 4. 召回路径验收

### 4.1 最小化恢复 ✓

```
raise 154 (QQ, min=true)
  AXMinimized=false : success
  AXRaise           : success
  activate          : true
  前台 App = QQ (pid 2325) ✓
```

### 4.2 AX 双写铺满 ✓

```
fill 154 (QQ)
  visibleFrame(AX 系) = (0, 33, 1470, 840)
  写入前 (290, 148, 820, 628)
  第 1 遍: position success · size success
  第 2 遍: position success · size success
  写入后 (0, 33, 1470, 839) ✓
```

坐标换算（AX 左上原点 ↔ AppKit 左下原点）正确。**结果高度 839 而非 840，差 1pt**，是 QQ 自身的尺寸约束。**M1 判定「已铺满」必须带容差，不能等值比较**（本 spike 用 <2pt）。

反例同样有价值：对通知中心的天气 widget 执行 fill，`position success · size failure` —— **部分窗口拒绝改尺寸**。M4 接管最大化必须处理这种拒绝，不能假定写入总成功。

### 4.3 无 AX 引用的存量窗口：激活 App 粗路 ✓

计划书 §4 兜底路径。

```
activate 28626 (Arc)
  激活前: AX 窗口 0 个 · 当前 Space 3
  activate: true
  激活后: AX 窗口 2 个 · 当前 Space 456
    wid 79210 · Space 456 · full=true · "macOS Dock和窗口管理的痛点分析 - Claude"
  结论: 补抓到 2 个新 AX 引用 ✓
```

**原生全屏窗口被正确识别**（`AXFullScreen=true`），Space 由系统自动切换，动画原生，标题在补抓后可读。

### 4.4 持有既有 AX 引用，召回其他 Space 的普通窗口 ✓（但目标是宿主 App，不具一般性）

计划书 §4 常规路径。**这是 M1 最高频的交互**：bar 存着早先抓到的引用，用户站在别的 Space 上点格子。

```
hold-raise 79455 (Code)
  抓取时: Space 3
  （用户手动切到 Space 477）
  召回前: 当前 Space 477
  引用存活检查: 读标题 = "plan.md — Moor"     ← 旧引用跨 Space 依然有效
  AXRaise: success · activate: true
  前台 App = Code ✓
  当前 Space = 3（已跨 Space 切换）
  该窗口回到当前 Space 的 AX 列表: 是 ✓
```

**AX 引用可长期持有。** 跨 Space 后照样读标题、照样 raise，系统自动完成 Space 切换，动画原生。M1 的索引不需要每次重抓引用。

⚠️ **焦点这一半不算数**：本机的 shell 跑在 VS Code 集成终端里，Code 是本 CLI 进程的宿主 App，而本例的目标恰好就是 Code 自己。激活自身宿主在协作式激活下本就放行，证明不了一般情形。一般情形由 4.5、4.6 覆盖。

### 4.5 持有既有 AX 引用，召回其他 Space 的**全屏**窗口 ✓

全屏窗口独占一个 Space，而终端在另一个 Space，人手切换构造不出场景（要敲命令就得切回终端，窗口随即离开当前 Space）。因此由 `roundtrip` 命令自动完成往返：激活目标 → 抓引用 → 激活回原 App（离开该 Space）→ 用旧引用召回。

```
roundtrip 28626 79210 —— 往返: Code → Arc → Code → 用旧引用召回
  起点 Space 3 · 前台=Code(69397)
  ① 抓到 wid 79210 · full=true · Space 456 · "Fun"
  ② 激活回 Code，现在 Space 3；该窗口已不在 AX 枚举结果里（符合预期）
  ③ 引用存活检查: 读标题 = "Fun"  ✓
     AXRaise: success · activate: true
     0.5s: 前台=Arc(28626) ✓ · Space 456
     结果: 焦点已转移到目标 ✓ · 当前 Space 456（已跨 Space 切回）· 该窗口回到 AX 列表 ✓
```

全屏窗口与普通窗口行为一致，无特殊性。焦点在 0.5s 内到位。

### 4.6 对照组：目标为非宿主 App 的普通窗口 ✓

排除 4.4 的宿主 App 混淆变量。

```
roundtrip 2382 —— 往返: Arc → 微信 → Arc → 用旧引用召回
  起点 Space 456 · 前台=Arc(28626)
  ① 抓到 wid 79034 · full=false · Space 477 · "微信"
  ② 激活回 Arc，现在 Space 456
  ③ 引用存活检查: 读标题 = "微信"  ✓
     0.5s: 前台=微信(2382) · [AX焦点=微信(2382)] ✓ · Space 477
     结果: 焦点已转移到目标 ✓ · 当前 Space 477 · 该窗口回到 AX 列表 ✓
```

**协作式激活（cooperative activation）不构成障碍。** 后台进程调用 `NSRunningApplication.activate()` 可正常夺取焦点，目标是否为宿主 App、是否全屏均无影响。计划书 §4 常规路径完整成立，**无需 `_SLPSSetFrontProcessWithOptions` 一类强制夺焦的私有符号**。

## 5. 观测数据

### 5.1 性能

**AX 全量枚举 1765–1883ms / 72 个 App**（约 25ms/App，串行，每 App 1 个跨进程 AX 调用，`AXUIElementSetMessagingTimeout` 设为 1s）。

这个数字**不威胁计划书 §4 的轮询兜底**——该通道用的是 CGWindowList/SLS 对账（单次调用，毫秒级），AX 枚举是 AXObserver 事件驱动、按 App 增量进行的。1.9s 只是冷启动全量扫描一次的代价。**M1 不做优化**，如确有必要再谈（并行化是现成手段）。

### 5.2 AXError 目录

| 错误 | 出现处 | 性质 |
|---|---|---|
| `illegalArgument` (-25201) | 访达的桌面窗口调 `_AXUIElementGetWindow` | 已知边界。该元素 `subrole == nil`，可据此过滤 |
| `cannotComplete` (-25204) | 6 个 helper 进程取 `kAXWindowsAttribute`（Browser Helper / Clash Verge Networking / OrbStack Networking / Raycast ×3） | 快速返回，非超时。这些是不拥有窗口的辅助进程 |

### 5.3 subrole 分布

真窗口一律 `AXStandardWindow`。非窗口混入物：

- `AXUnknown` —— 通知中心天气 widget、BetterDisplay 的 1×1 隐形窗口
- `AXSystemDialog` —— Alcove
- `nil` —— 访达桌面窗口

Arc 提供了一个额外佐证：每次激活 Arc，其 AX 列表里都会多出一个 `AXUnknown`、空标题、`full=false` 的窗口，且 wid 每次都变（观测到 79490 → 80146），是随激活创建的临时覆盖层。用户确认只开了一个 Arc 窗口。**`AXStandardWindow` 过滤规则正确排除了它。**

**M1 的 bar 过滤规则：AX 侧取 `AXStandardWindow`；CG 侧取 layer 0 + ordered-in + 尺寸阈值。**

### 5.4 焦点读取的两个陷阱（本 spike 亲历，M1 必须避开）

判定「窗口是否召回成功」离不开读当前前台 App。两条来源各有坑，早期版本因此得出过**完全错误的结论**（曾判定「协作式激活拒绝焦点转移」，实为测量 bug）：

| 来源 | 陷阱 |
|---|---|
| `NSWorkspace.frontmostApplication` | **权威，但靠通知更新，必须跑 run loop 才刷新。** 无 run loop 的进程里它永远返回启动那一刻的缓存值。早期版本用 `usleep` 采样 8 拍，8 拍全是同一个值——不是焦点没变，是这个值根本不会变 |
| 系统级 AX `kAXFocusedApplication` | **实时，但对 Electron / Chromium 系 App 返回 nil**（VS Code、Arc 实测均读不到；原生的微信可读）。这类 App 的 AX 树默认惰性启用 |

**M1 结论：焦点判定以 `NSWorkspace` 为准（bar 本身是 GUI App，run loop 天然在跑，此坑自动消失）；系统级 AX 焦点仅作诊断，不作判定依据。**

### 5.5 Space 归属是多值

通知中心的窗口观测到 `Space=477/3` —— 一个窗口可同时属于多个 Space（`canJoinAllSpaces` 类窗口）。**索引里 Space 归属必须是数组，不能是单值。**

---

## 6. 留给 M1 的问题

### 6.1 跨 Space 窗口的标题来源 —— **已由 M0.5 关闭，采纳方案 A（见 8.1）**

> 下述分析在 M0 交付时的约束下成立。项目方随后同意引入屏幕录制权限，实测 `kCGWindowName` 覆盖率 100%，**方案 1（标题缓存）与方案 2（懒获取）均无须实现**，仅作为个别 App 的局部兜底保留。

这是 M0 暴露出的、计划书尚未定案的唯一硬问题。其他 Space 上的非最小化窗口没有 AX 引用，因而读不到标题；而 `kCGWindowName` 需要屏幕录制权限（属不必要的权限扩张，已否决）。可选路径：

1. **标题缓存（推荐）** —— 窗口总是先在某个 Space 被创建，创建时它在当前 Space、有 AX 引用、标题可读。记下来，之后即使跑到别的 Space 也用缓存标题。成本极低，覆盖绝大多数情况。
2. **懒获取** —— 冷启动时缓存为空的存量窗口，bar 上先只显示 App 图标，用户激活后补抓转正（即本 spike 的 `activate` 路径，见 4.3）。
3. **AltTab 式短暂拉取**（计划书 §5 边缘 hack）—— 有闪屏与 1 秒预算缺陷，作为最后手段。

倾向 1 + 2 组合，3 不做。

### 6.2 次要残留

微信 pid 8921（accessory）下的 1470×840 surface 判为 ordered-out，未经用户逐项核对，是判别式唯一未证伪的边缘情形。

## 7. 计划书需要更新的地方

- §4「数据流三通道」应补入 **ordered-in 判别式**——CGWindowList 对账通道若不做此过滤，会把大量僵尸 surface 当成窗口。本项目实测噪声比为 29:3。
- §5 私有 API 清单第 1 层应加入 **`SLSWindowIsOrderedIn`**（只读，风险等同该层其余符号）。
- §4「窗口索引」的 Space 归属字段改为数组。
- §4「召回路径」全部实测成立，无需修改；可补一句：焦点判定须用 `NSWorkspace.frontmostApplication`（见 5.4）。
- §5 私有 API 清单**不需要新增写操作类别**——协作式激活不构成障碍，强制夺焦的私有符号（`_SLPSSetFrontProcessWithOptions` 等）无须引入。「长期仅进第 1 层只读区」成立。
- 但「**MVP 一个私有符号**」已被证伪：对账通道离开 `SLSWindowIsOrderedIn` 无法区分真窗口与僵尸 surface（噪声比 29:3）。MVP 实需第 0 层 1 个 + 第 1 层 3 个（`SLSMainConnectionID` / `SLSCopySpacesForWindows` / `SLSWindowIsOrderedIn`）。
- §9 开放问题可移除「AX 通道是否可靠」一类疑虑，新增「跨 Space 窗口标题来源」（6.1）。


---

## 8. 附录：M0.5 —— 屏幕录制权限与后台成本实测

M0 交付后，项目方提出两条新输入：**（一）屏幕录制权限可以接受；（二）App 在后台必须尽量轻量。** 前者直接影响 6.1 的取舍，后者是新的硬约束。为此加了 `bench` 命令实测。

注意 TCC 归属：权限须授予**宿主进程**（本机为 VS Code，因 shell 跑在其集成终端内），非 moorspike 本身；否则 `kCGWindowName` 会被静默抹成 nil，覆盖率会误报为 0。

### 8.1 标题覆盖率：100%，6.1 可用方案 A 关闭

| wid | App | AX 标题 | CG 标题 |
|---|---|---|---|
| **79210** | **Arc** | **—（无 AX 引用）** | **"New chat - Claude"** |
| 79455 | Code | plan.md — Moor | plan.md — Moor |
| 154 | QQ | QQ | QQ |
| 81318 | 系统设置 | 录屏与系统录音 | 录屏与系统录音 |
| 79459 | 访达 | 下载 | 下载 |

ordered-in 真窗口 5 个，有 CG 标题的 5 个，**覆盖率 100%**。

加粗那行是决定性证据：**它正是催生 6.1 的那个窗口**——跨 Space、原生全屏、无 AX 引用。CG 标题完整可读。

因此 **6.1 的标题缓存 + 懒获取机制不需要实现**；跨 Space 标题由对账通道直接提供。

样本局限：本机仅 5 个真窗口，非广覆盖测试。但历史上最可疑的 Electron / Chromium 系（Code、Arc）均通过，AltTab「CG 标题不可靠」的经验很可能是旧系统时代的遗留。M1 若遇到 CG 标题为空的 App，退回懒获取即可，属局部兜底而非架构回滚。

### 8.2 判别式修正：最小化窗口是 ordered-out

```
Ghostty — 最小化: ordered-in=false · 在 CG 候选里=是 · 在 AX 里=是
微信   — 最小化: ordered-in=false · 在 CG 候选里=是 · 在 AX 里=是
```

**`ordered-in == true` 会把最小化窗口一并筛掉**，且最小化窗口与僵尸 surface 在 CG 层面无法区分。

**M1 过滤规则须为：`ordered-in == true` **或** AX 报告 `AXMinimized == true`。** 这也意味着**即使有了 CG 标题，AX 通道依然不可省**——最小化窗口只能由 AX 认领（第 2 节已验证其跨 Space 始终留在 AX 中，并集闭合无洞）。

### 8.3 后台成本

| 项 | 实测 |
|---|---|
| `CGWindowListCopyWindowInfo(.optionAll)` ×10 | 平均 **10.11ms**（4.84 ~ 41.78ms，333 个窗口） |
| `SLSWindowIsOrderedIn` ×64 | 1.30ms（20µs/次） |
| `SLSCopySpacesForWindows` ×64 | 0.93ms（15µs/次） |
| **一次完整对账 tick** | **≈ 12.3ms** |
| （对照）AX 全量枚举 | 1824ms / 70 个 App，仅冷启动 |

按 2 秒周期轮询约合 0.6% 单核。SLS 逐窗口调用成本可忽略，开销集中在 CG 列表本身（333 个窗口的字典构造）。

**冷启动可大幅优化**：CG 通道已能指出哪些 pid 拥有真窗口（70 个 App 中仅约 6 个），AX 枚举只需探这几个，预计可从 1824ms 压至 150ms 量级。这是权限带来的意外收益。

### 8.4 待项目方决策

1. **是否采纳方案 A**（M1 即引入屏幕录制权限）。计划书 §5 原本就在 M5 缩略图时需要该权限，本决策是**提前，不是新增**；但计划书 §4 现明文写着「标题读取坚持走 AX，不走 CGWindowList……属不必要的权限扩张」，需相应修订。
2. **「后台轻量」约束是否写入计划书 §2 设计原则**，并量化为预算：稳态除对账 tick 外无常驻定时器；tick 预算 ≤ 15ms；缩略图与悬停预览严格按需，绝不常驻流式采集。
3. **待实机确认**：macOS 26 是否会周期性重新提示屏幕录制权限。若一个日用工具反复弹窗，方案 A 的账要重算。
