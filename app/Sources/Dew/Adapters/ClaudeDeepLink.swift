import AppKit
import Foundation

/// Claude 深链的三块知识：会话注册表、聚焦路由的功能开关、导入的一次性账本。
///
/// 背景（都由实测与 Claude.app 自身的路由代码确认）：
///
/// - `claude://resume?session=<日志uuid>` 是**导入**。桌面端日志原文：
///   `Resume deep link: importing CLI session …`。跟一次就多一条无标题会话，
///   在侧边栏显示为「General coding session」。
/// - `claude://code/<bridgeSessionId>` 才是**聚焦**：路由里
///   `findSessionIdByBridgeSessionId` 找到本地那条会话并跳过去，不新建。
///   但它挂在一个功能开关后面，部分版本是关的——点了毫无反应，
///   只在日志里留一行 `code session deep link gated off`。
/// - `claude://code/local_<id>` 不被接受（`unrecognized code path`）。

// MARK: - 会话注册表

/// Claude 桌面端为每条会话存一份 `local_<uuid>.json`，里面有
/// `cliSessionId`（本地日志的 uuid）与 `bridgeSessionIds`。
/// 靠它把「一个日志文件」翻译成「桌面端认识的 bridge id」——
/// 只扫日志正文的话覆盖率差得多（实测 2/13 vs 11/13），因为 bridge 行不是每个会话都写。
enum ClaudeSessionIndex {
    private static var root: URL {
        PathHelper.home.appending(path: "Library/Application Support/Claude/claude-code-sessions")
    }

    /// 路径 + mtime 为键的解析缓存：每拍只 stat，不重复解 JSON。
    nonisolated(unsafe) private static var cache: [String: (mtime: Date, cli: String?, bridge: String?)] = [:]
    nonisolated(unsafe) private static var byCLI: [String: String] = [:]
    nonisolated(unsafe) private static var builtAt: Date = .distantPast
    private static let lock = NSLock()
    /// 注册表变动很慢，没必要每秒重扫。
    private static let rebuildInterval: TimeInterval = 20

    /// 该 CLI 会话在桌面端的 bridge id。没有就是没有孪生会话（或还没生成）。
    static func bridgeID(forCLISession uuid: String) -> String? {
        lock.lock()
        let stale = Date().timeIntervalSince(builtAt) >= rebuildInterval
        let hit = byCLI[uuid]
        lock.unlock()
        if let hit, !stale { return hit }
        if stale { rebuild() }
        lock.lock(); defer { lock.unlock() }
        return byCLI[uuid]
    }

    private static func rebuild() {
        let files = PathHelper.files(in: root, ext: "json")
        var map: [String: String] = [:]
        var next: [String: (mtime: Date, cli: String?, bridge: String?)] = [:]

        for url in files where url.lastPathComponent.hasPrefix("local_") {
            let mtime = PathHelper.modifiedAt(url)
            lock.lock()
            let cached = cache[url.path]
            lock.unlock()

            let entry: (mtime: Date, cli: String?, bridge: String?)
            if let cached, cached.mtime == mtime {
                entry = cached
            } else {
                guard let data = try? Data(contentsOf: url),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                // 一条会话可能有多个 bridge id（重连过），最后一个是当前那条
                let bridge = (obj["bridgeSessionIds"] as? [String])?.last
                entry = (mtime, obj["cliSessionId"] as? String, bridge)
            }
            next[url.path] = entry
            if let cli = entry.cli, let bridge = entry.bridge { map[cli] = bridge }
        }

        lock.lock()
        cache = next
        byCLI = map
        builtAt = Date()
        lock.unlock()
    }
}

// MARK: - 聚焦路由的功能开关

/// 跟 `claude://code/…` 之后回头看一眼 Claude 的日志：被开关挡掉就退回 Finder。
///
/// 没有任何接口能问「这个开关开没开」，日志是唯一的信号。挡掉一次就记住，
/// 之后直接走 Finder，不再让用户白等——Claude 更新后重启 Dew 会重新试。
enum ClaudeFocusGate {
    nonisolated(unsafe) private static var knownOff = false
    private static let lock = NSLock()

    private static var logFile: URL {
        PathHelper.home.appending(path: "Library/Logs/Claude/main.log")
    }
    /// 开关关着：这台机器上聚焦路由整体不可用，记住它，之后别再白等。
    private static let gateMarker = "code session deep link gated off"
    /// 路由不认识这个 id：只说明**这一条**链接不行（比如 id 形态不对），
    /// 不代表开关是关的——别因为一条坏链接把整个聚焦能力停掉。
    private static let rejectedMarker = "unrecognized code path"

    static func isKnownOff() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return knownOff
    }

    /// 跟链接，然后确认它真的被处理了。被功能开关挡掉时调用 `onBlocked`，
    /// 由调用方决定退到哪一步（Dew 里是「导入一次」，再不行才是 Finder）。
    static func open(_ url: URL, onBlocked: @escaping @Sendable () -> Void) {
        guard !isKnownOff() else { onBlocked(); return }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { onBlocked(); return }

        let before = fileSize(logFile)
        NSWorkspace.shared.open(url)

        Task.detached(priority: .utility) {
            // 日志是异步落盘的，给它一点时间；分两次看，慢的机器也能覆盖。
            for delay in [400, 900] {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard let tail = appended(to: logFile, since: before) else { continue }
                if tail.contains(gateMarker) {
                    markOff()
                    onBlocked()
                    return
                }
                if tail.contains(rejectedMarker) {
                    onBlocked()
                    return
                }
            }
        }
    }

    /// 同步的小函数：NSLock 不能直接在 async 上下文里用（Swift 6 会直接报错）。
    private static func markOff() {
        lock.lock(); knownOff = true; lock.unlock()
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }

    /// 只读 `since` 之后新增的那一段，避免把整份日志读进来。
    private static func appended(to url: URL, since offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard end > offset else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
