import Foundation

/// Claude Code 接入。
///
/// 会话：~/.claude/projects/<slug>/<uuid>.jsonl
/// 定时任务：~/.claude/scheduled-tasks/<taskId>/SKILL.md
///
/// 状态判据（实测得出）：
///   最后一条是 assistant 且 stop_reason == "tool_use"，说明工具调用已发出但还没有对应的
///   tool_result。此时若文件长时间没动 → 卡在等你授权；刚动过 → 正在执行。
struct ClaudeCodeAdapter: AgentAdapter {
    let kind: AgentKind = .claudeCode

    /// 超过这个时长没有新事件，就认为不是在执行而是在等人
    private let stallThreshold: TimeInterval = 25
    /// 超过这个时长的会话不再展示
    private let staleThreshold: TimeInterval = 8 * 3600
    /// 「已完成」只在这个窗口内算数。更早的降为空闲——否则一天下来会堆几十条，
    /// 把定时任务挤出视口，跟「定时任务是一等公民」的设计意图相反。
    private let doneWindow: TimeInterval = 2 * 3600

    fileprivate var projectsDir: URL { PathHelper.home.appending(path: ".claude/projects") }
    private var scheduledDir: URL { PathHelper.home.appending(path: ".claude/scheduled-tasks") }

    var watchPaths: [URL] { [projectsDir, scheduledDir] }

    func loadSessions() -> [AgentSession] {
        PathHelper.files(in: projectsDir, ext: "jsonl", modifiedWithin: staleThreshold)
            .compactMap(parseSession)
    }

    private func parseSession(_ url: URL) -> AgentSession? {
        let lines = FileTail.lines(of: url)
        guard !lines.isEmpty else { return nil }

        let mtime = PathHelper.modifiedAt(url)
        let age = Date().timeIntervalSince(mtime)

        var cwd: String?
        var lastAssistantStop: String?
        var lastAssistantText: String?
        var lastToolName: String?
        var lastType: String?
        var sawToolResultAfterToolUse = false

        for line in lines {
            guard let obj = FileTail.json(line) else { continue }
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            guard let type = obj["type"] as? String else { continue }

            switch type {
            case "assistant":
                lastType = type
                let msg = obj["message"] as? [String: Any]
                lastAssistantStop = msg?["stop_reason"] as? String
                sawToolResultAfterToolUse = false
                if let blocks = msg?["content"] as? [[String: Any]] {
                    for b in blocks {
                        switch b["type"] as? String {
                        case "text":
                            if let t = b["text"] as? String, !t.isEmpty { lastAssistantText = t }
                        case "tool_use":
                            lastToolName = b["name"] as? String
                        default: break
                        }
                    }
                }

            case "user":
                lastType = type
                let msg = obj["message"] as? [String: Any]
                if let blocks = msg?["content"] as? [[String: Any]],
                   blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    sawToolResultAfterToolUse = true
                }

            default:
                continue
            }
        }

        let state: SessionState
        if age > staleThreshold {
            state = .idle
        } else if lastType == "assistant", lastAssistantStop == "tool_use", !sawToolResultAfterToolUse {
            // 工具已请求、结果未回。停太久就是在等人点同意。
            state = age > stallThreshold ? .needsYou : .running
        } else if lastType == "assistant" {
            // 收尾了，等你说下一句
            if age <= stallThreshold { state = .running }
            else { state = age <= doneWindow ? .done : .idle }
        } else if lastType == "user" {
            state = age > stallThreshold ? .idle : .running
        } else {
            state = .idle
        }

        let summary: String = {
            if state == .needsYou, let tool = lastToolName { return L(.waitingApproval, tool) }
            if state == .running, let tool = lastToolName { return oneLine(tool) }
            if let t = lastAssistantText { return oneLine(t) }
            if let tool = lastToolName { return oneLine(tool) }
            return "—"
        }()

        return AgentSession(
            id: url.path,
            kind: kind,
            projectName: PathHelper.shortName(for: cwd),
            cwd: cwd,
            state: state,
            summary: summary,
            changedAt: mtime,
            sourcePath: url.path,
            // Claude 桌面端的深链：把这个 CLI 会话导入并打开。
            // 参数名 session 来自桌面端自身的路由代码（wl.Resume → searchParams.get("session")）。
            deepLink: URL(string: "claude://resume?session=\(url.deletingPathExtension().lastPathComponent)")
        )
    }

    // MARK: - 定时任务
    //
    // ⚠️ 未经真实数据验证：本机当前一条定时任务都没有，该目录尚不存在。
    // 按已知契约（每个 taskId 一个目录，内含 SKILL.md）防御性实现，
    // 解析不出来就返回空，不会崩。等有真实任务后需要复核字段名。

    func loadScheduledTasks() -> [ScheduledTask] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: scheduledDir,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return dirs.compactMap { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let skill = dir.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: skill, encoding: .utf8) else { return nil }

            let fm2 = Frontmatter(text)
            let name = fm2["name"] ?? dir.lastPathComponent
            let cron = fm2["cronExpression"] ?? fm2["schedule"]
            let enabled = (fm2["enabled"] ?? "true") != "false"
            let next = fm2["nextRunAt"].flatMap(ISO8601DateFormatter().date(from:))

            return ScheduledTask(
                id: dir.path,
                kind: kind,
                name: name,
                scheduleText: cron.map(Cron.humanize) ?? L(.scheduled),
                nextRun: next ?? cron.flatMap { Cron.nextRun(after: Date(), expression: $0) },
                enabled: enabled,
                sourcePath: skill.path
            )
        }
    }
}

/// 极简 YAML frontmatter 读取器：只取顶层 `key: value`，够用即可。
struct Frontmatter {
    private var map: [String: String] = [:]

    init(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return }
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let k = String(t[t.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if !k.isEmpty { map[k] = v }
        }
    }

    subscript(_ key: String) -> String? { map[key] }
}

// MARK: - 用量（本地估算，非官方额度）
//
// ⚠️ Claude Code 不把限额百分比写到本地磁盘。日志里的 error.rateLimits
// 只在撞限额报错时才出现，不能当持续数据源。
// 所以这里给出的是**本地日志累计的 token 用量**，不是「还剩多少额度」。
// 界面上必须把这个区别写清楚，见 AgentQuota.isLocalEstimate。

extension ClaudeCodeAdapter {
    func loadQuota() -> AgentQuota? {
        Self.usageIndex.scan(dir: projectsDir)

        let fiveHour = Self.usageIndex.totals(within: 5 * 3600)
        let week     = Self.usageIndex.totals(within: 7 * 24 * 3600)

        // 官方额度优先。拿不到时退回本地累计——但两者在界面上必须区分得开。
        ClaudeUsageAPI.refreshIfNeeded()
        if let official = ClaudeUsageAPI.current(), !official.isEmpty {
            // Keychain 那份优先，~/.claude.json 兜底
            let plan = ClaudeUsageAPI.planLabel() ?? Self.planLabel()
            return AgentQuota(kind: kind, planType: plan,
                              windows: official, isLocalEstimate: false, sampledAt: Date())
        }

        guard week.total > 0 else { return nil }
        return AgentQuota(
            kind: kind,
            planType: Self.planLabel(),
            windows: [
                QuotaWindow(label: L(.winLast5h), usedPercent: nil, resetsAt: nil,
                            totalTokens: fiveHour.total, outputTokens: fiveHour.output),
                QuotaWindow(label: L(.winLast7d), usedPercent: nil, resetsAt: nil,
                            totalTokens: week.total, outputTokens: week.output),
            ],
            isLocalEstimate: true,
            sampledAt: Date()
        )
    }

    /// adapter 是值类型、每次刷新都会被复制，索引必须挂在类型上才能跨刷新累积。
    static let usageIndex = ClaudeUsageIndex()

    /// 套餐等级来自 ~/.claude.json 的 oauthAccount，是普通配置文件，不碰任何凭据。
    /// "default_claude_max_5x" → "Max 5x"
    static func planLabel() -> String? {
        let url = PathHelper.home.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }

        let tier = (account["userRateLimitTier"] as? String)
                ?? (account["organizationRateLimitTier"] as? String)
        guard var t = tier else {
            return (account["organizationType"] as? String)?
                .replacingOccurrences(of: "claude_", with: "")
                .capitalized
        }
        t = t.replacingOccurrences(of: "default_", with: "")
             .replacingOccurrences(of: "claude_", with: "")
        // max_5x → Max 5x
        let parts = t.split(separator: "_").map(String.init)
        guard let head = parts.first else { return nil }
        let rest = parts.dropFirst().joined(separator: " ")
        return rest.isEmpty ? head.capitalized : "\(head.capitalized) \(rest)"
    }
}
