import Foundation

/// Codex 接入。
///
/// 会话：~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
/// 定时任务：~/.codex/automations/<id>/automation.toml
///
/// 状态判据：Codex 的日志里状态是**显式事件**，不用启发式猜。
///   event_msg.payload.type ∈ { task_started, task_complete, turn_aborted }
struct CodexAdapter: AgentAdapter {
    let kind: AgentKind = .codex

    private let stallThreshold: TimeInterval = 25
    private let staleThreshold: TimeInterval = 8 * 3600
    /// 「已完成」只在这个窗口内算数，更早的降为空闲。
    private let doneWindow: TimeInterval = 2 * 3600

    private var sessionsDir: URL { PathHelper.home.appending(path: ".codex/sessions") }
    private var automationsDir: URL { PathHelper.home.appending(path: ".codex/automations") }

    var watchPaths: [URL] { [sessionsDir, automationsDir] }

    func loadSessions() -> [AgentSession] {
        // sessions 目录按 YYYY/MM/DD 分层，积年累月有成千上万个文件。
        // 刷新是秒级轮询，绝不能每次都全树枚举——只看今天和昨天两个目录。
        recentDayDirs()
            .flatMap { PathHelper.files(in: $0, ext: "jsonl", modifiedWithin: staleThreshold) }
            .compactMap(parseSession)
    }

    private func recentDayDirs() -> [URL] {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        f.timeZone = .current
        let now = Date()
        return [now, now.addingTimeInterval(-86400)]
            .map { sessionsDir.appending(path: f.string(from: $0)) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private func parseSession(_ url: URL) -> AgentSession? {
        let lines = FileTail.lines(of: url)
        guard !lines.isEmpty else { return nil }

        let mtime = PathHelper.modifiedAt(url)
        let age = Date().timeIntervalSince(mtime)

        var cwd: String?
        var lastLifecycle: String?     // task_started / task_complete / turn_aborted
        var lastAgentMessage: String?
        var lastFinalAnswer: String?

        for line in lines {
            guard let obj = FileTail.json(line) else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]

            if type == "session_meta", let c = payload?["cwd"] as? String, !c.isEmpty {
                cwd = c
            }
            guard type == "event_msg", let p = payload, let pt = p["type"] as? String else { continue }

            switch pt {
            case "task_started", "task_complete", "turn_aborted":
                lastLifecycle = pt
                if pt == "task_complete", let m = p["last_agent_message"] as? String {
                    lastFinalAnswer = m
                }
            case "agent_message":
                if let m = p["message"] as? String, !m.isEmpty {
                    lastAgentMessage = m
                    if (p["phase"] as? String) == "final_answer" { lastFinalAnswer = m }
                }
            default:
                break
            }
        }

        // cwd 兜底：从首行再捞一次（tail 可能没覆盖到 session_meta）
        if cwd == nil, let head = try? String(contentsOf: url, encoding: .utf8).split(separator: "\n").first,
           let obj = FileTail.json(String(head)),
           let p = obj["payload"] as? [String: Any] {
            cwd = p["cwd"] as? String
        }

        let state: SessionState
        switch lastLifecycle {
        case "task_started":
            // Codex 没有显式的「等待授权」事件。开跑了却久久没有新事件，视为卡住等人。
            state = age > stallThreshold ? .needsYou : .running
        case "task_complete":
            state = age > doneWindow ? .idle : .done
        case "turn_aborted":
            state = .idle
        default:
            state = age > stallThreshold ? .idle : .running
        }

        let summary = oneLine(lastFinalAnswer ?? lastAgentMessage ?? "—")

        return AgentSession(
            id: url.path,
            kind: kind,
            projectName: PathHelper.shortName(for: cwd),
            cwd: cwd,
            state: state,
            summary: summary,
            changedAt: mtime,
            sourcePath: url.path
        )
    }

    // MARK: - 定时任务（已实测，字段确定）

    func loadScheduledTasks() -> [ScheduledTask] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: automationsDir,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return dirs.compactMap { dir in
            let toml = dir.appending(path: "automation.toml")
            guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
            let t = MiniTOML(text)

            let name = t["name"] ?? dir.lastPathComponent
            let status = (t["status"] ?? "ACTIVE").uppercased()
            let rrule = t["rrule"] ?? ""

            return ScheduledTask(
                id: dir.path,
                kind: kind,
                name: name,
                scheduleText: RRule.humanize(rrule),
                nextRun: RRule.nextRun(after: Date(), rrule: rrule),
                enabled: status == "ACTIVE",
                sourcePath: toml.path
            )
        }
    }
}

/// 只解析顶层 `key = "value"` / `key = 123` 的极简 TOML 读取器。
/// automation.toml 的结构就这么简单，不值得引一个依赖进来。
struct MiniTOML {
    private var map: [String: String] = [:]

    init(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if !k.isEmpty { map[k] = v }
        }
    }

    subscript(_ key: String) -> String? { map[key] }
}

// MARK: - 额度（真实数据）
//
// Codex 把限额直接写进会话日志：
//   event_msg.payload.type == "token_count"
//     .rate_limits.primary { used_percent, window_minutes, resets_at }
//     .info.total_token_usage { total_tokens, output_tokens, ... }
// 取最近一个会话文件里的最后一条即可。

extension CodexAdapter {
    func loadQuota() -> AgentQuota? {
        guard let newest = recentDayDirs()
            .flatMap({ PathHelper.files(in: $0, ext: "jsonl") })
            .max(by: { PathHelper.modifiedAt($0) < PathHelper.modifiedAt($1) })
        else { return nil }

        var rateLimits: [String: Any]?
        var usage: [String: Any]?
        var stamp: Date?

        for line in FileTail.lines(of: newest) {
            guard let obj = FileTail.json(line),
                  obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  p["type"] as? String == "token_count" else { continue }
            rateLimits = p["rate_limits"] as? [String: Any] ?? rateLimits
            usage = (p["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] ?? usage
            if let ts = obj["timestamp"] as? String {
                stamp = ISO8601DateFormatter().date(from: ts) ?? stamp
            }
        }
        guard rateLimits != nil || usage != nil else { return nil }

        let total = usage?["total_tokens"] as? Int
        let output = usage?["output_tokens"] as? Int

        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = rateLimits?[key] as? [String: Any],
                  let pct = w["used_percent"] as? Double else { continue }
            let minutes = w["window_minutes"] as? Int
            windows.append(QuotaWindow(
                label: Self.windowLabel(minutes: minutes),
                usedPercent: pct,
                resetsAt: (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                       ?? (w["resets_at"] as? Int).map { Date(timeIntervalSince1970: Double($0)) },
                totalTokens: key == "primary" ? total : nil,
                outputTokens: key == "primary" ? output : nil
            ))
        }
        // 一个额度窗口都没有，但有 token 统计时，至少把用量露出来
        if windows.isEmpty, total != nil {
            windows.append(QuotaWindow(label: L(.winTotal), usedPercent: nil, resetsAt: nil,
                                       totalTokens: total, outputTokens: output))
        }

        return AgentQuota(
            kind: kind,
            planType: rateLimits?["plan_type"] as? String,
            windows: windows,
            isLocalEstimate: false,
            sampledAt: stamp ?? PathHelper.modifiedAt(newest)
        )
    }

    private static func windowLabel(minutes: Int?) -> String {
        guard let m = minutes else { return L(.winQuota) }
        switch m {
        case 10080: return L(.winWeek)
        case 1440:  return L(.winToday)
        case 300:   return L(.win5h)
        case 60:    return L(.win1h)
        default:
            if m % 1440 == 0 { return L(.winNDays, m / 1440) }
            if m % 60 == 0   { return L(.winNHours, m / 60) }
            return L(.winNMinutes, m)
        }
    }
}
