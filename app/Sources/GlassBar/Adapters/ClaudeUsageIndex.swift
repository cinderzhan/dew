import Foundation

/// Claude Code 本地 token 用量的增量索引。
///
/// 为什么要索引：算「近 7 天用量」需要看全量日志，几十 MB。
/// 每次刷新都全读一遍是不可接受的，所以记住每个文件已消费到的字节偏移，
/// 只解析新增的那一段。文件变小（轮转/重写）时该文件重来。
///
/// 线程安全：AgentStore 在后台队列里调用它，用锁保护即可，无需 actor。
final class ClaudeUsageIndex: @unchecked Sendable {

    struct Sample {
        let at: Date
        let total: Int
        let output: Int
    }

    private struct FileState {
        var offset: UInt64
        var samples: [Sample]
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    /// 只保留这段时间内的样本，防止无限增长
    private let retention: TimeInterval = 8 * 24 * 3600

    func scan(dir: URL) {
        let urls = PathHelper.files(in: dir, ext: "jsonl", modifiedWithin: retention)
        for url in urls { consume(url) }
        prune()
    }

    /// 汇总最近 `window` 秒内的用量
    func totals(within window: TimeInterval, now: Date = Date()) -> (total: Int, output: Int) {
        let cutoff = now.addingTimeInterval(-window)
        lock.lock(); defer { lock.unlock() }
        var t = 0, o = 0
        for state in files.values {
            for s in state.samples where s.at >= cutoff {
                t += s.total
                o += s.output
            }
        }
        return (t, o)
    }

    // MARK: -

    private func consume(_ url: URL) {
        let path = url.path
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0

        lock.lock()
        var state = files[path] ?? FileState(offset: 0, samples: [])
        // 文件变小说明被重写过，之前的偏移作废
        if size < state.offset { state = FileState(offset: 0, samples: []) }
        let start = state.offset
        lock.unlock()

        guard size > start else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // 末尾可能是半行，留到下次再处理
        var consumed = data.count
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            consumed = lastNewline + 1
        } else {
            return
        }

        let slice = data.prefix(consumed)
        guard let text = String(data: slice, encoding: .utf8) else {
            // 解码失败也要推进偏移，否则会卡在同一段反复重试
            lock.lock(); files[path] = FileState(offset: start + UInt64(consumed), samples: state.samples); lock.unlock()
            return
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()

        var newSamples: [Sample] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = FileTail.json(String(line)),
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            let input   = usage["input_tokens"] as? Int ?? 0
            let output  = usage["output_tokens"] as? Int ?? 0
            let cacheR  = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheW  = usage["cache_creation_input_tokens"] as? Int ?? 0

            let ts = obj["timestamp"] as? String
            let at = ts.flatMap { fmt.date(from: $0) ?? fallback.date(from: $0) }
                   ?? PathHelper.modifiedAt(url)

            newSamples.append(Sample(at: at, total: input + output + cacheR + cacheW, output: output))
        }

        lock.lock()
        state.offset = start + UInt64(consumed)
        state.samples.append(contentsOf: newSamples)
        files[path] = state
        lock.unlock()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retention)
        lock.lock(); defer { lock.unlock() }
        for (path, var state) in files {
            state.samples.removeAll { $0.at < cutoff }
            if state.samples.isEmpty, state.offset == 0 { files.removeValue(forKey: path) }
            else { files[path] = state }
        }
    }
}
