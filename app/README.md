# Dew

桌面常驻的可折叠 Agent 状态条 + 个人待办。macOS only。
设计与范围见上级目录的 `PRD.md`，视觉方向为「C 玻璃 · 素皮肤」。

## LOGO 与图标

源文件在 `../assets/logo/`：

- `dew-icon.svg` — 应用图标（1024 方形，macOS 圆角方底 + 一粒露珠）
- `dew-mark-mono.svg` — 单色标，菜单栏 / 小尺寸 / 深色底用（`currentColor`）
- `dew-wordmark.svg` — 字标（露珠 + Dew）

改了 `dew-icon.svg` 之后跑 `../assets/logo/render-icon.sh`，会重新生成 `Dew.icns`，
`build.sh` 自动打进 bundle。菜单栏图标用的是 SF Symbol `drop`，和 LOGO 同一意象。

## 构建

```bash
./build.sh
```

产物在 `build/Dew.app`。

**不走 SwiftPM**：纯 Command Line Tools 环境下 `PackageDescription` 链接是坏的，
`build.sh` 直接调 `swiftc` 编译再手工组 bundle。装了完整 Xcode 后可以改回 SwiftPM。

### 已知环境坑

若编译报大量 `redefinition of module 'SwiftBridging'`，是 Command Line Tools
安装残留了旧版 modulemap，跟本项目无关：

```bash
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
        /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.stale-backup
```

## 运行

```bash
open build/Dew.app
```

没有 Dock 图标（`LSUIElement`），入口在菜单栏。折叠条常驻桌面，单击展开，
Esc 或点右上角箭头收起，拖动条身可移动，位置自动记忆。

### 开发期开关

| 环境变量 | 作用 |
|---|---|
| `DEW_DEBUG=1` | 打印窗口与屏幕诊断 |
| `DEW_EXPANDED=1` | 启动 2.5 秒后自动展开 |
| `DEW_EXPANDED=todo` | 展开并直接切到待办 tab |
| `DEW_EXPANDED=usage` | 展开并直接切到用量 tab |
| `DEW_SETTINGS=1` | 同时展开设置面板 |
| `DEW_DEMO=1` | 演示模式：会话 / 定时任务 / 额度 / 待办全是假数据，不读 Agent 目录、不碰 `todos.json`。截图用，可与上面的开关叠加 |

## 结构

```
Models/      四态、会话、定时任务、待办
Adapters/    每个 Agent 一个 adapter，实现 AgentAdapter 协议
  AgentAdapter.swift    协议 + 文件尾部读取工具
  ClaudeCodeAdapter     ~/.claude/projects、~/.claude/scheduled-tasks
  CodexAdapter          ~/.codex/sessions、~/.codex/automations
  CursorAdapter         ~/.cursor/projects/<slug>/agent-transcripts（无 tool_result，状态靠 mtime 推断）
  DSHAdapter            ~/.dsh/sessions 与 ~/Library/Application Support/dsh-desktop/harness/sessions
                        （DSH CLI / DSH Desktop 同格式：逐帧追加的 zstd JSONL，只解末尾几帧；
                        解压借 Homebrew zstd 或 DSH Desktop 自带 Electron 的 Node 模式，见 ZstdDecoder）
  AntigravityAdapter    （未注册，roadmap）会话正文加密，只能读 brain/<id>/task.md，判不出「等你介入」
  Schedule.swift        RRULE 求值、cron 求值、相对时间
  ClaudeUsageIndex      Claude token 用量的增量索引（记字节偏移，只读新增部分）
Store/       聚合层与持久化，UI 不认识任何具体 Agent
  FileWatcher.swift     FSEvents 递归监听，文件一变立刻刷新
Design/      皮肤 token（可变）与 Metrics（皮肤不可改）
Views/       折叠条、展开面板、两个 tab
App/         NSPanel 悬浮窗、位置记忆、菜单栏入口
```

## Claude 官方额度（默认关闭，需用户显式开启）

设置面板里的「读取 Claude 官方额度」**默认关**。开启后 app 会：

- 从钥匙串读取 Claude Code 自己存的登录凭据（项名 `Claude Code-credentials`）
- 用它向 `api.anthropic.com/api/oauth/usage` 查询限额窗口
- 凭据只在内存中，不落盘、不记日志、不发往其他任何地方

关着的时候 `ClaudeUsageAPI` 不碰钥匙串、不发请求。这是**未公开接口**，可能随 Claude 更新失效。

它需要 `claude` CLI 的凭据有效。若只在桌面端用 Claude Code，
那份凭据可能早已过期，接口会返回 401，界面自动退回本地 token 累计。

修复：

```bash
claude auth login
```

凭据只有 `claude` CLI 自己会续期（桌面端用的是另一套，不会帮它续），所以只用桌面端的话它会一直过期着。

**过期时 Dew 不会去撞那个必然的 401**：`credential()` 读到的凭据带 `expiresAt`，
过期就直接把失败原因记成 `.credentialExpired`，跳过请求，并且每 5 分钟才回钥匙串复查一次
——既能在你跑完 `claude auth login` 后自动恢复，又不至于每两分钟弹一次密码框。

失败原因是**类型化**的（`ClaudeUsageAPI.Failure`）而不是拼好的字符串，
界面才能本地化地把话说清楚。用量页会直接显示为什么没有进度条，
不然用户只看到「突然只剩数字」，无从判断该自己动手还是等接口恢复。

首次运行时 macOS 会弹窗询问是否允许访问钥匙串，选「**始终允许**」（不是「允许」）。
签名身份稳定的前提下这只会问一次，见下一节。

token 读到后**进程内缓存**，只在快过期或接口回 401 时才重读钥匙串——
所以即便授权没记住，一次启动也最多问一次（此前每 120 秒读一次，没记住授权就每两分钟弹一次）。

若每次都要求输入**登录密码**而且「始终允许」不生效：这是钥匙串分区列表（partition list）在拦
——该项由 Claude CLI（Apple 开发者签名）创建，分区列表里只有它自己的 team，
自签名的 Dew 永远匹配不上，点了「始终允许」也记不住。用户可以自行执行一次（需输一次密码，之后不再弹）：

```bash
security set-generic-password-partition-list -S "apple-tool:,apple:,unsigned:" -s "Claude Code-credentials" -k <登录密码>
```

不加 `-k` 会交互式询问。正式上 Developer ID 签名后此问题自然消失。

## 窗口交互约定

展开态**关掉了** `isMovableByWindowBackground`——整片背景可拖会抢走复选框、
滑块的 mouseDown，滑块尤其明显（拖它变成拖窗口）。所以展开后只有两处可拖：
**顶部标签栏**与**底部计数栏**，走 `performDrag`，手感同原生标题栏。
折叠态仍是整条可拖。

透明度调节同时作用于着色层与磨砂层。只调着色是压不透的：
`NSVisualEffectView` 的材质始终满强度，想真正看见桌面必须让磨砂本身淡出。
最低档保留 14% 的底，全透会只剩文字飘在桌面上，读不了。

## 语言

中英文切换在设置面板里。所有文案都在 `Design/L10n.swift` 的一张表里，
新增文案加一个 key、写两种语言即可；`L10n.current` 是 nonisolated 的，
adapter 在后台线程拼文案时也能读到。默认跟随系统语言。

## 「已完成」的生命周期

两段式：这次打开面板只**登记**为看过（列表照常显示），**下次**再打开才隐藏。
一段式（打开即隐藏）会在下一拍刷新时把它们压没，体感是「刚点开就消失」。
入口只在 `RootView` 的 `onChange(of: chrome.isExpanded)` 一处，
所有展开路径（点击、菜单栏、调试开关）都经过它。见 `AgentStore.beginViewingAgents / endViewing`。

## 待办的跨日清理

每分钟检查一次，跨过零点时按类别处理：

| 类别 | 完成之后 |
|---|---|
| 每日重复 | 取消勾选、留在原地——它的意义就是明天再做一遍 |
| 高优 / 普通 | 隔天直接删除，不让昨天的成就占今天的视觉 |

**首次运行只补日期戳、不清理。** `lastRolloverDay` 这个 UserDefaults 键兼作「跑过没有」的标记：
没有值即首次，此时把所有已完成项补成今天，规则从今天起生效、不追溯。
少了这一步，用户升级上来的那一刻，几天前完成的项会集体消失——而这条规则是他们升级之后才知道的。

`TodoStore` 的 `directory` 与 `defaults` 可注入，只为了测试能在临时目录里跑。
**别想着用改 HOME 来隔离测试**：`Application Support` 的路径不受 HOME 影响，
那样只会写进用户的真实 `todos.json`（这个坑踩过一次，删掉了真实数据）。

## 性能约束（改动前必读）

**会话刷新与额度刷新必须是两个独立任务。** 额度索引首次要扫全量日志，动辄几秒；
若绑进同一个串行刷新，首屏会一直是「0 会话」，这几秒里所有刷新都排队，
用户感受到的就是「响应慢」。见 `AgentStore.refreshSessions` / `refreshQuota`。

## 踩过的渲染坑（改动前必读）

1. **残影（旧文字浅色印在面板上）**：透明无边框窗口的阴影由内容快照计算，
   内容更新后快照不自动失效。修复是宿主视图 `layout()` 里 `invalidateShadow()`。
   不要试图用 compositingGroup / copiesOnScroll / 调整重绘策略来修——都试过，无效。
2. **不要用 `alphaValue` 调磨砂透明度**，视图会脱离不透明绘制路径。
   透明度低档直接撤掉 NSVisualEffectView，只留纯 SwiftUI 白纱层。
3. **白纱必须保底且必须是白的**：全透后透出的是桌面本色，深色桌面会让面板发灰发脏。
4. **每个 tab 的 body 必须有显式 VStack 容器**，并列视图直接返回时
   在 switch + ScrollView 里的展平不可靠。

## 签名身份与分发（免费路线）

`build.sh` 优先用本机自签的稳定身份 **Dew Dev** 签名；找不到就退回临时签名。
临时签名每次构建都变，钥匙串的「始终允许」随之失效、反复弹窗——稳定身份是为了解决这个。

没有这个身份时这样创建（一次性，免 sudo）：

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout gb.key -out gb.crt \
  -subj "/CN=Dew Dev" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -out gb.p12 -inkey gb.key -in gb.crt -name "Dew Dev" -passout pass:x
security import gb.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db gb.crt
rm gb.key gb.p12
```

打包给同事：

```bash
./dist.sh
```

产物 `dist/Dew.dmg`（主包，文件名固定，根 README 的下载按钮指向
`releases/latest/download/Dew.dmg`，发新版不用改链接）和 `dist/Dew-<版本>.zip`（备用）。
自签 + 未公证，收件人第一次打开要绕过 Gatekeeper（macOS 15 走 系统设置 → 隐私与安全性 →「仍要打开」；
macOS 14 右键 → 打开；或 `xattr -cr`），之后正常双击。

发版：改 `build.sh` 里的 `CFBundleShortVersionString`，`./dist.sh`，然后
`gh release create v<版本> dist/Dew.dmg dist/Dew-<版本>.zip`。
正式对外发布需要 Apple Developer ID 签名 + 公证，到时只需把 `build.sh` 里的 IDENTITY 换掉并加一步 notarytool。

## 点击会话 → 跳回 Agent 桌面端

| Agent | 深链 | 来源 |
|---|---|---|
| Claude Code | `claude://resume?session=<会话uuid>`（**默认不跟**） | Claude 桌面端路由代码（`wl.Resume` → `searchParams.get("session")`）。见下方警告 |
| Codex | `codex://threads/<线程id>` | ChatGPT 桌面端注册的 scheme；定时任务跳 `automation.toml` 的 `target_thread_id` |
| Cursor | `cursor://file/<项目目录>` | 未找到按聊天的深链，退一步打开项目 |
| DSH Desktop | 无 scheme（只有内部用的 `dsh-recovery://`） | 退一步拉起 `/Applications/DSH Desktop.app`；CLI 会话定位到会话目录 |

没有深链、或系统里没有 app 认领该 scheme 时，退回 Finder 定位日志文件。
这些都是各家未公开的内部路由，版本更新后可能失效。

### Claude 的两条深链，语义完全不同

| 深链 | 行为 | 来源 |
|---|---|---|
| `claude://code/<bridgeSessionId>` | **聚焦**桌面端已有的那条会话，什么都不新建 | 路由里 `findSessionIdByBridgeSessionId` → `getSessionRoute`（`resolved: local_twin`） |
| `claude://resume?session=<日志uuid>` | **导入**一份副本 | 桌面端日志原文：`Resume deep link: importing CLI session …` |

跟 `resume` 一次，同一个对话在侧边栏就变成两条，新的那条没有标题、显示为
「General coding session」。Claude 日志里留着这些导入记录，一次不落。

**bridge id 从哪来**：`~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`，
每条会话一份，含 `cliSessionId`（本地日志 uuid）与 `bridgeSessionIds`。
只扫日志正文里的 `bridge-session` 行覆盖率差得多（实测 2/13），查注册表能到 12/13。
`claude://code/local_<id>` 不被接受（`unrecognized code path`），只认 `cse_` / `session_` 前缀。

### 聚焦路由挂在一个功能开关后面

部分 Claude 版本里它是关的：点了毫无反应，只在
`~/Library/Logs/Claude/main.log` 留一行 `code session deep link gated off`。
没有接口能问「开没开」，所以 `ClaudeFocusGate` 跟完链接之后回头读那一小段新增日志，
发现被挡就记住（本进程内不再重试）并回调给调用方。

点击的完整退路是三级：**聚焦 →（被挡）→ 导入 → 访达定位**。
中间那级只受设置开关约束。等哪天官方打开功能开关，第一级自然生效，后两级再也不会被触发。

日志里区分两种「没成功」，含义完全不同，不能混为一谈：
`code session deep link gated off` 是这台机器上聚焦整体不可用（记住，之后别再白等）；
`unrecognized code path` 只说明**这一条** id 不被接受，不该因为一条坏链接把整个聚焦能力停掉。

### 导入是幂等的——别加「只导入一次」的上限

桌面端导入后记录的 id 就是 `local_<日志uuid>`，**重复导入复用同一条**。
实测连点 5 次导入两个会话，列表里仍是各一条。

所以同一个对话最多有两条记录：真正的桌面会话（有标题、有 bridge id），
和导入产生的孪生（无标题、无 bridge id，显示为「General coding session」）。
曾经加过一个「同一条会话只导入一次」的账本，结果是第二次点击莫名其妙落到访达——
上限解决的是一个并不存在的问题，已经删掉。

## 数据

**全部只读。绝不写入任何 Agent 的数据目录。**

自己的数据只有一份：`~/Library/Application Support/Dew/todos.json`。

## 刷新机制

两条腿走路，缺一不可：

- **FSEvents**：文件一变立刻回调（0.15s 合并窗口），负责「内容变了」
- **1 秒节拍器**：负责**不由文件驱动**的时间态变化——比如「停超过 25 秒算等你介入」，
  这种转换没有任何文件会写，只能靠时间推算

一次刷新实测约 7ms，1 秒一拍的开销可以忽略。额度另走 15 秒慢节拍，
因为它要扫全量日志。

## 接入新 Agent

1. 写一个 struct 实现 `AgentAdapter`
2. 在 `AgentKind` 里加 case
3. 在 `AgentStore.init` 的默认 adapters 数组里加一个实例

可选实现 `loadScheduledTasks()` 与 `loadQuota()`，不实现就是没有。

UI 与 store 层不需要任何改动。
