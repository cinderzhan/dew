<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo/dew-dotgrid-dark.svg">
    <img src="assets/logo/dew-dotgrid.svg" alt="Dew" width="260">
  </picture>
</p>

<p align="center">
  一条常驻桌面、可折叠的极简状态条：左边管所有 AI Agent 的活，右边管自己的活。<br>
  <sub>A tiny always-on-top macOS bar that shows what your coding agents (Claude Code / Codex / Cursor) are doing — plus your own to-dos. Read-only, local, no account.</sub>
</p>

---

## 它解决什么

同时跑多个 Agent 时，你不知道哪个在跑、哪个跑完了、哪个**卡住在等你授权**——只能挨个切窗口看。定时任务什么时候触发也没有任何可视化。

Dew 把这些压成**一行**：折叠态只显示最需要你介入的那一件事；展开才看全部。

| 折叠态信号（按优先级） | 示例 |
|---|---|
| 等你介入 | `⏸ 1 个等你授权` |
| 已完成待查看 | `✓ 2 个已完成` |
| 进行中 | `▶ 3 个进行中` |
| 全部空闲 | `全部空闲` |

## 功能

- **Agents** — 每个会话一行：项目名、来源、状态 + 持续时长、最后一条动作摘要。点击跳回对应的桌面端（`claude://resume` / `codex://threads` / `cursor://file`），没有深链就退回 Finder 定位日志。
- **定时任务** — Claude Code `scheduled-tasks` 与 Codex `automations`，显示下次触发时间（cron / RRULE 本地求值）。
- **To-do** — 高优 / 普通 / 每日重复 三类，键盘优先，纯本地 JSON。
- **用量** — Codex 真实额度（来自会话日志）、Claude Code 本地 token 累计；可选开启官方额度接口（默认关，详见下）。
- 中 / 英文切换，透明度可调，位置自动记忆，菜单栏入口，不占 Dock。

## 支持的 Agent

| Agent | 会话状态 | 等你介入 | 定时任务 | 额度 | 数据源 |
|---|:-:|:-:|:-:|:-:|---|
| Claude Code | ✅ | ✅ | ✅ | ✅ | `~/.claude/projects/**/*.jsonl`、`~/.claude/scheduled-tasks/` |
| Codex | ✅ | ✅ | ✅ | ✅ | `~/.codex/sessions/`、`~/.codex/automations/` |
| Cursor | ✅ | 推断 | — | — | `~/.cursor/projects/<slug>/agent-transcripts/` |
| Antigravity | roadmap | | | | 会话正文加密，暂未启用 |

**全部只读，绝不写入任何 Agent 的数据目录。** 接新 Agent 只需实现一个 `AgentAdapter`，UI 与 store 层零改动——见 [app/README.md](app/README.md#接入新-agent)。

## 安装 / 构建

要求 macOS 14+（Apple Silicon），装有 Xcode Command Line Tools。

```bash
cd app
./build.sh        # 产物 build/Dew.app
open build/Dew.app
```

不依赖 SwiftPM，`build.sh` 直接调 `swiftc` 组 bundle。打包给别人用 `./dist.sh`（自签未公证，对方第一次右键 → 打开）。环境坑、签名身份、调试开关等见 [app/README.md](app/README.md)。

## 关于隐私

- 自己的数据只有一份：`~/Library/Application Support/Dew/todos.json`。
- 「读取 Claude 官方额度」**默认关闭**。开启后才会从钥匙串读 Claude Code 自己的登录凭据，只发往 `api.anthropic.com`，凭据只存内存、不落盘、不记日志。这是未公开接口，可能随 Claude 更新失效。
- 不联网、无账号、无遥测（上面那个可选开关除外）。

## 仓库结构

```
app/            macOS 应用源码与构建脚本（Swift / AppKit + SwiftUI）
assets/logo/    图标与 LOGO 源文件（SVG / icns），render-icon.sh 重新生成图标
PRD.md          产品定义、状态语义、各 Agent 数据源实测记录
skins.html / visual-directions.html   早期视觉方向探索稿
```

## License

[MIT](LICENSE)
