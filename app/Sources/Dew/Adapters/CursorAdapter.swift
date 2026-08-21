import Foundation

/// Cursor 接入。
///
/// 会话：~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl
/// 每行 {"role": "user"|"assistant", "message": {"content": [blocks]}}，
/// block 类型实测只有 text / tool_use——**没有 tool_result**，也没有逐行时间戳。
/// 所以状态完全靠「最后一条是什么 + 文件多久没动」推断；
/// 和 Claude 的区别是没法用 tool_result 确认工具跑完了没。
///
/// 定时任务 / 额度：Cursor 本地没有可读的对应数据，不提供。
struct CursorAdapter: AgentAdapter {
    let kind: AgentKind = .cursor

    private let stallThreshold: TimeInterval = 25
    private let staleThreshold: TimeInterval = 8 * 3600
    private let doneWindow: TimeInterval = 2 * 3600

    private var projectsDir: URL { PathHelper.home.appending(path: ".cursor/projects") }

    var watchPaths: [URL] { [projectsDir] }

    func loadSessions() -> [AgentSession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsDir,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var out: [AgentSession] = []
        for project in projects {
            let transcripts = project.appending(path: "agent-transcripts")
            guard fm.fileExists(atPath: transcripts.path) else { continue }
            for url in PathHelper.files(in: transcripts, ext: "jsonl", modifiedWithin: staleThreshold) {
                if let s = parseSession(url, projectSlug: project.lastPathComponent) { out.append(s) }
            }
        }
        return out
    }

    private func parseSession(_ url: URL, projectSlug: String) -> AgentSession? {
        let lines = FileTail.lines(of: url)
        guard !lines.isEmpty else { return nil }

        let mtime = PathHelper.modifiedAt(url)
        let age = Date().timeIntervalSince(mtime)

        var lastRole: String?
        var lastAssistantHadToolUse = false
        var lastToolName: String?
        var lastText: String?

        for line in lines {
            guard let obj = FileTail.json(line), let role = obj["role"] as? String else { continue }
            lastRole = role
            guard let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            if role == "assistant" {
                lastAssistantHadToolUse = false
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_use":
                        lastAssistantHadToolUse = true
                        lastToolName = b["name"] as? String
                    case "text":
                        // Cursor 会把正文写成 [REDACTED]，那不算摘要
                        if let t = b["text"] as? String, !t.isEmpty, !t.contains("[REDACTED]") {
                            lastText = t
                        }
                    default: break
                    }
                }
            }
        }

        let state: SessionState
        if age > staleThreshold {
            state = .idle
        } else if lastRole == "assistant", lastAssistantHadToolUse {
            // 工具调用发出后没下文。刚发的算在跑，停久了多半在等你点同意。
            state = age > stallThreshold ? .needsYou : .running
        } else if lastRole == "assistant" {
            if age <= stallThreshold { state = .running }
            else { state = age <= doneWindow ? .done : .idle }
        } else {
            state = age > stallThreshold ? .idle : .running
        }

        let summary: String = {
            if state == .needsYou, let tool = lastToolName { return L(.waitingApproval, tool) }
            if state == .running, let tool = lastToolName { return oneLine(tool) }
            if let t = lastText { return oneLine(t) }
            if let tool = lastToolName { return oneLine(tool) }
            return "—"
        }()

        let cwd = Self.resolveSlug(projectSlug)
        return AgentSession(
            id: url.path,
            kind: kind,
            projectName: cwd.map(PathHelper.shortName(for:)) ?? Self.lastSegment(projectSlug),
            cwd: cwd,
            state: state,
            summary: summary,
            changedAt: mtime,
            sourcePath: url.path,
            // Cursor 没有公开的「打开某个聊天」深链，只能退一步打开对应项目
            deepLink: cwd.flatMap { URL(string: "cursor://file/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)") }
        )
    }

    // MARK: - slug → 路径

    /// Cursor 把 cwd 里的 "/" 和空格都换成 "-" 做目录名，而目录名本身也可能含 "-"。
    /// 逐段还原：每一步同时尝试「这里是 /」「这里是 -」「这里是空格」三种可能，
    /// 能在磁盘上找到对应目录的分支才保留。找不回来就退回「最后一段」。
    static func resolveSlug(_ slug: String) -> String? {
        if slug == "empty-window" { return nil }
        let parts = slug.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        let fm = FileManager.default
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        // 候选 = (已确认的父路径, 尚未闭合的名字片段)
        var states: [(path: String, pending: String)] = [("", "")]
        for p in parts {
            var next: [(String, String)] = []
            for st in states {
                let names = st.pending.isEmpty ? [p] : [st.pending + "-" + p, st.pending + " " + p]
                for name in names {
                    let cand = st.path + "/" + name
                    if isDir(cand) { next.append((cand, "")) }
                    next.append((st.path, name))
                }
            }
            // 防爆：只留前 12 个候选
            states = Array(next.prefix(12))
        }
        return states.first(where: { $0.pending.isEmpty && !$0.path.isEmpty })?.path
    }

    static func lastSegment(_ slug: String) -> String {
        slug.split(separator: "-").last.map(String.init) ?? slug
    }
}
