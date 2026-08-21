import Foundation

/// 所有 Agent 接入点的统一契约（PRD 4.5）。
/// 新增一个 Agent = 新写一个 adapter，UI 与 store 层完全不用改。
protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }

    /// 需要监听变化的目录。为空表示该 adapter 不参与文件监听。
    var watchPaths: [URL] { get }

    /// 发现并解析当前会话。只读，绝不写入 Agent 的数据目录。
    func loadSessions() -> [AgentSession]

    /// 读取定时任务。不支持的 Agent 返回空数组。
    func loadScheduledTasks() -> [ScheduledTask]

    /// 读取限额 / 用量。拿不到就返回 nil。
    /// 注意区分「官方剩余额度」与「本地日志累计用量」——见 AgentQuota.isLocalEstimate。
    func loadQuota() -> AgentQuota?
}

extension AgentAdapter {
    func loadScheduledTasks() -> [ScheduledTask] { [] }
    func loadQuota() -> AgentQuota? { nil }
}

// MARK: - 共用工具

enum FileTail {
    /// 只读文件末尾若干字节，避免把几十 MB 的 JSONL 整个读进内存。
    /// 丢弃第一段可能被截断的行。
    static func lines(of url: URL, maxBytes: Int = 256 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var result = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // 起点不在文件开头时，首行大概率是半截的
        if start > 0, !result.isEmpty { result.removeFirst() }
        return result
    }

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum PathHelper {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 从 cwd 取一个短名用于展示
    static func shortName(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func modifiedAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// 递归列出目录下所有指定扩展名的文件
    static func files(in dir: URL, ext: String, modifiedWithin seconds: TimeInterval? = nil) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        let cutoff = seconds.map { Date().addingTimeInterval(-$0) }
        for case let url as URL in en {
            guard url.pathExtension == ext else { continue }
            if let cutoff, PathHelper.modifiedAt(url) < cutoff { continue }
            out.append(url)
        }
        return out
    }
}

/// 单行摘要：压掉换行、截断、去掉 markdown 噪声
func oneLine(_ s: String, limit: Int = 64) -> String {
    var t = s.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
    if t.count > limit { t = String(t.prefix(limit)) + "…" }
    return t
}
