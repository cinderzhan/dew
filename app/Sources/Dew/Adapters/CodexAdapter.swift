import Foundation

/// Codex 接入。
///
/// 会话：~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
/// 定时任务：~/.codex/automations/<id>/automation.toml
///
/// 状态判据：Codex 的日志里状态是**显式事件**，不用启发式猜。
///   event_msg.payload.type ∈ { task_started, task_complete, turn_aborted }
///
/// 子代理：Codex 会把 sub-agent 开成**独立的 rollout 文件**，首行 session_meta 里带
/// `parent_thread_id`。父线程派活之后自己就停笔等结果，单看父文件像是卡住了；
/// 子文件又是一个「会话」。所以这里按 parent_thread_id 把子代理**折进父线程**：
/// 一个用户可见的线程只占一行，状态以父线程的生命周期为准，活跃时间取全家最新。
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
        // sessions 目录按 YYYY/MM/DD 分层，积年累月有成千上万个文件，不能每拍全树枚举。
        // 但注意：**目录日期是线程的创建日，不是活跃日**。一个三天前开的会话今天还在用，
        // 文件仍在三天前的目录里。所以不能只看今天——回溯最近 90 天的目录，
        // 再用 mtime 过滤；列目录很便宜，真正的开销只在被命中的那几个文件上。
        let parsed = recentDayDirs(days: 90)
            .flatMap { PathHelper.files(in: $0, ext: "jsonl", modifiedWithin: staleThreshold) }
            .compactMap(parseFile)
        return collapseSubagents(parsed).map(makeSession)
    }

    /// 一个 rollout 文件解析出的原始事实，还没定状态。
    private struct Rollout {
        let url: URL
        let threadID: String?
        let parentThreadID: String?
        let cwd: String?
        let mtime: Date
        let lastLifecycle: String?
        let lastMessage: String?
        var children: [Rollout] = []
    }

    /// 把带 parent_thread_id 的文件挂到父线程名下；父线程不在本轮结果里（太旧 / 不在扫描范围）
    /// 的子代理保持独立一行，宁可多显示也别凭空消失。
    private func collapseSubagents(_ all: [Rollout]) -> [Rollout] {
        var byID: [String: Rollout] = [:]
        for r in all { if let id = r.threadID { byID[id] = r } }
        // 一直往上找到最顶层的、本轮能看到的祖先；子代理再开子代理也折到同一行。
        func root(of r: Rollout) -> String? {
            var cur = r, hops = 0
            while let pid = cur.parentThreadID, pid != cur.threadID, let p = byID[pid], hops < 8 {
                cur = p; hops += 1
            }
            return cur.threadID
        }
        var roots: [String: Rollout] = [:]
        var standalone: [Rollout] = []
        for r in all {
            guard let id = r.threadID else { standalone.append(r); continue }
            let rid = root(of: r) ?? id
            if rid == id { roots[id] = roots[id] ?? r; continue }      // 自己就是顶层
            if roots[rid] == nil { roots[rid] = byID[rid] }
            roots[rid]!.children.append(r)
        }
        return Array(roots.values) + standalone
    }

    private func makeSession(_ r: Rollout) -> AgentSession {
        // 全家最新的那份文件代表「现在在干什么」：子代理在跑时摘要就是子代理的进度。
        let latest = ([r] + r.children).max { $0.mtime < $1.mtime } ?? r
        let age = Date().timeIntervalSince(latest.mtime)

        let state: SessionState
        switch r.lastLifecycle {
        case "task_started":
            // Codex 没有显式的「等待授权」事件。开跑了却久久没有新事件（包括子代理也没动静），视为卡住等人。
            state = age > stallThreshold ? .needsYou : .running
        case "task_complete":
            state = age > doneWindow ? .idle : .done
        case "turn_aborted":
            state = .idle
        default:
            state = age > stallThreshold ? .idle : .running
        }

        return AgentSession(
            id: r.url.path,
            kind: kind,
            projectName: PathHelper.shortName(for: r.cwd),
            cwd: r.cwd,
            state: state,
            summary: oneLine(latest.lastMessage ?? r.lastMessage ?? "—"),
            changedAt: latest.mtime,
            sourcePath: r.url.path,
            // ChatGPT 桌面端（Codex）注册的深链，直达线程。
            // 文件名里也带线程 id（rollout-<时间>-<uuid>.jsonl），session_meta 读不到时从文件名兜底。
            deepLink: Self.threadLink(r.threadID ?? Self.threadIDFromFilename(r.url))
        )
    }

    private func recentDayDirs(days: Int) -> [URL] {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        f.timeZone = .current
        let now = Date()
        return (0..<days)
            .map { sessionsDir.appending(path: f.string(from: now.addingTimeInterval(-Double($0) * 86400))) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    private func parseFile(_ url: URL) -> Rollout? {
        let lines = FileTail.lines(of: url)
        guard !lines.isEmpty else { return nil }

        // 首行是这个文件**自己的** session_meta。注意子代理 / fork 出来的文件会把父线程的历史
        // 整段抄进来，后面还会再出现父线程的 session_meta——所以身份只认首行，
        // 事件只认自己开始之后的（靠时间戳过滤掉抄来的历史）。
        var cwd: String?
        var threadID: String?
        var parentThreadID: String?
        var ownStart: String?   // ISO 字符串，同格式下字典序即时间序，免去解析
        if let head = FileTail.firstLine(of: url), let obj = FileTail.json(head),
           obj["type"] as? String == "session_meta", let p = obj["payload"] as? [String: Any] {
            if let c = p["cwd"] as? String, !c.isEmpty { cwd = c }
            threadID = (p["id"] as? String) ?? (p["session_id"] as? String)
            parentThreadID = p["parent_thread_id"] as? String
            ownStart = p["timestamp"] as? String
        }

        var lastLifecycle: String?     // task_started / task_complete / turn_aborted
        // 摘要优先级：本 turn 里 agent 最新的话 > 本 turn 的用户提问（刚开跑还没输出时） > 上一轮的最终回答。
        // 新 turn 开始时前两项清空，否则「进行中」的行会一直挂着上一轮的回答，像是没动。
        var turnAgentMessage: String?
        var turnUserPrompt: String?
        var lastAnswer: String?

        for line in lines {
            guard let obj = FileTail.json(line) else { continue }
            guard obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any],
                  let pt = p["type"] as? String else { continue }
            if let own = ownStart, let ts = obj["timestamp"] as? String, ts < own { continue }

            switch pt {
            case "task_started":
                lastLifecycle = pt
                turnAgentMessage = nil
                turnUserPrompt = nil
            case "task_complete", "turn_aborted":
                lastLifecycle = pt
                if pt == "task_complete", let m = p["last_agent_message"] as? String, !m.isEmpty {
                    turnAgentMessage = m
                }
            case "agent_message":
                if let m = p["message"] as? String, !m.isEmpty { turnAgentMessage = m }
            case "user_message":
                if let m = p["message"] as? String, !m.isEmpty { turnUserPrompt = Self.stripTags(m) }
            default:
                break
            }
            if let m = turnAgentMessage { lastAnswer = m }
        }

        return Rollout(url: url, threadID: threadID, parentThreadID: parentThreadID, cwd: cwd,
                       mtime: PathHelper.modifiedAt(url), lastLifecycle: lastLifecycle,
                       lastMessage: turnAgentMessage ?? turnUserPrompt ?? lastAnswer)
    }

    /// 定时任务的心跳提问是一坨 XML（<heartbeat><automation_id>…），去掉标签只留正文。
    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    static func threadLink(_ id: String?) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    /// rollout-2026-08-20T19-33-43-<uuid>.jsonl → <uuid>
    static func threadIDFromFilename(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        // uuid 是最后 36 个字符（8-4-4-4-12）
        guard stem.count > 36 else { return nil }
        let tail = String(stem.suffix(36))
        return tail.filter { $0 == "-" }.count == 4 ? tail : nil
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
                sourcePath: toml.path,
                // automation 发到哪个线程，就跳哪个线程
                deepLink: Self.threadLink(t["target_thread_id"])
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
        guard let newest = recentDayDirs(days: 90)
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
