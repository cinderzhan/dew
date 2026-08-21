import Foundation

/// Antigravity 接入 —— **只能接一半，原因要说清楚**：
///
/// 它的会话正文 `~/.gemini/antigravity*/conversations/*.pb` 是加密的
///（高熵、开头不是合法 protobuf），读不了。能读的是
/// `~/.gemini/antigravity*/brain/<id>/task.md`：明文任务清单（- [ ] / - [x]），
/// 旁边的 `.metadata.json` 有 `summary` 与 `updatedAt`。
///
/// 所以：能知道「在做什么、做到哪」，**不能知道「是否卡着等你」**——
/// 本 adapter 永远不会产出 needsYou。
/// 另外本机两个月没用过 Antigravity，以下逻辑未经活数据验证。
struct AntigravityAdapter: AgentAdapter {
    let kind: AgentKind = .antigravity

    private let stallThreshold: TimeInterval = 60
    private let staleThreshold: TimeInterval = 8 * 3600
    private let doneWindow: TimeInterval = 2 * 3600

    private var roots: [URL] {
        [".gemini/antigravity-ide/brain", ".gemini/antigravity/brain"]
            .map { PathHelper.home.appending(path: $0) }
    }

    var watchPaths: [URL] { roots }

    func loadSessions() -> [AgentSession] {
        let fm = FileManager.default
        var out: [AgentSession] = []
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { continue }
            for dir in dirs {
                let task = dir.appending(path: "task.md")
                guard fm.fileExists(atPath: task.path) else { continue }
                let mtime = max(PathHelper.modifiedAt(task),
                                Self.metadataUpdatedAt(dir.appending(path: "task.md.metadata.json")) ?? .distantPast)
                let age = Date().timeIntervalSince(mtime)
                guard age <= staleThreshold else { continue }
                guard let text = try? String(contentsOf: task, encoding: .utf8) else { continue }

                let (title, open, closed) = Self.parse(text)
                let state: SessionState
                if age <= stallThreshold {
                    state = .running
                } else if open == 0, closed > 0 {
                    state = age <= doneWindow ? .done : .idle
                } else {
                    // 还有没勾的项但一段时间没动：可能在等你，也可能在思考。
                    // 没有证据支持「等你」，宁可报保守的「进行中」也不要误报红点。
                    state = .running
                }

                out.append(AgentSession(
                    id: dir.path,
                    kind: kind,
                    projectName: title ?? dir.lastPathComponent.prefix(8).description,
                    cwd: nil,
                    state: state,
                    summary: open > 0 ? "\(closed)/\(open + closed) · \(title ?? "task")" : (title ?? "task"),
                    changedAt: mtime,
                    sourcePath: task.path
                ))
            }
        }
        return out
    }

    private static func parse(_ md: String) -> (title: String?, open: Int, closed: Int) {
        var title: String?
        var open = 0, closed = 0
        for raw in md.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if title == nil, line.hasPrefix("# ") { title = String(line.dropFirst(2)) }
            if line.hasPrefix("- [ ]") { open += 1 }
            else if line.lowercased().hasPrefix("- [x]") { closed += 1 }
        }
        return (title, open, closed)
    }

    private static func metadataUpdatedAt(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = obj["updatedAt"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
