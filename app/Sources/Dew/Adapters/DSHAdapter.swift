import Foundation

/// DSH（DeepSeek Harness）接入：DSH Desktop 与 DSH CLI 共用同一套会话格式。
///
/// 会话：<root>/sessions/<cwd-slug>/session-<uuid>/session.jsonl[.zstd]
///   root 依次为 $DSH_HOME（默认 ~/.dsh，CLI）、
///              ~/Library/Application Support/dsh-desktop/harness（Desktop）、
///              ~/Library/Application Support/dsh-desktop-dev/harness。
///
/// 文件是**逐帧追加的 zstd 压缩 JSONL**，每一帧恰好对齐到行首，所以只解末尾几帧就够了。
/// macOS 没有系统级 zstd 库，Swift 解不了；这里借外部解码器：优先 Homebrew 的 `zstd`，
/// 没有就用 DSH Desktop 自带的 Electron 以 Node 模式跑 `zlib.zstdDecompressSync`
/// ——装了 DSH Desktop 的机器上一定有，不引入任何额外依赖。见 `ZstdDecoder`。
///
/// 状态判据（事件都是显式的）：
///   turn/start … turn/end{reason.kind: completed|error|…}
///   开着的 turn 久无新事件 → 等你介入（DSH 的 approval 等待没有单独事件，和 Codex 一样靠停顿推断）
struct DSHAdapter: AgentAdapter {
    let kind: AgentKind = .dsh

    private let stallThreshold: TimeInterval = 25
    private let staleThreshold: TimeInterval = 8 * 3600
    private let doneWindow: TimeInterval = 2 * 3600

    struct Root: Sendable {
        let url: URL
        let isDesktop: Bool
        var sessions: URL { url.appending(path: "sessions") }
    }

    static var roots: [Root] {
        let env = ProcessInfo.processInfo.environment
        let cli = env["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? PathHelper.home.appending(path: ".dsh")
        let appSupport = PathHelper.home.appending(path: "Library/Application Support")
        return [
            Root(url: cli, isDesktop: false),
            Root(url: appSupport.appending(path: "dsh-desktop/harness"), isDesktop: true),
            Root(url: appSupport.appending(path: "dsh-desktop-dev/harness"), isDesktop: true),
        ]
    }

    /// DSH Desktop 没有 URL scheme，点击只能把 app 拉到前台。
    static let desktopApp = URL(fileURLWithPath: "/Applications/DSH Desktop.app")

    var watchPaths: [URL] { Self.roots.map(\.sessions) }

    func loadSessions() -> [AgentSession] { loadSessions(within: staleThreshold) }

    func loadSessions(within window: TimeInterval) -> [AgentSession] {
        let fm = FileManager.default
        var out: [AgentSession] = []
        for root in Self.roots where fm.fileExists(atPath: root.sessions.path) {
            // 同一目录下若同时有明文和压缩版，认明文
            var byDir: [URL: URL] = [:]
            for url in PathHelper.files(in: root.sessions, ext: "jsonl", modifiedWithin: window)
                + PathHelper.files(in: root.sessions, ext: "zstd", modifiedWithin: window) {
                let name = url.lastPathComponent
                guard name == "session.jsonl" || name == "session.jsonl.zstd" else { continue }
                let dir = url.deletingLastPathComponent()
                if let existing = byDir[dir], existing.pathExtension == "jsonl" { continue }
                byDir[dir] = url
            }
            for url in byDir.values {
                if let s = parse(url, root: root) { out.append(s) }
            }
        }
        return out
    }

    // MARK: - 解析

    private func parse(_ url: URL, root: Root) -> AgentSession? {
        let mtime = PathHelper.modifiedAt(url)
        let age = Date().timeIntervalSince(mtime)
        let header = DSHFiles.header(of: url)
        let lines = DSHFiles.tailLines(of: url, mtime: mtime)
        guard !lines.isEmpty || header != nil else { return nil }

        var lastEndSeq = -1, lastActivitySeq = -1
        var endKind: String?, endError: String?
        var title: String?
        var turnUser: String?, turnAssistant: String?, lastAssistant: String?

        for line in lines {
            guard let obj = FileTail.json(line), let type = obj["type"] as? String else { continue }
            let seq = obj["seq"] as? Int ?? -1
            let data = obj["data"] as? [String: Any] ?? [:]
            switch type {
            case "turn/start":
                lastActivitySeq = seq
                turnUser = nil; turnAssistant = nil
            case "turn/end":
                lastEndSeq = seq
                let reason = data["reason"] as? [String: Any]
                endKind = reason?["kind"] as? String
                endError = (reason?["error"] as? [String: Any])?["message"] as? String
            case "step/start", "step/end", "tool/call", "tool/result":
                lastActivitySeq = seq
            case "assistant/message":
                lastActivitySeq = seq
                let content = (data["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { turnAssistant = text; lastAssistant = text }
            case "user/message":
                // 只认用户亲手发的；运行时上下文、skill 提示也是 user/message，但 source.kind 不是 user 或带系统标签
                guard (data["source"] as? [String: Any])?["kind"] as? String == "user" else { continue }
                let content = data["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("Current runtime context") {
                    turnUser = text
                }
            case "session/title":
                if let t = data["title"] as? String, !t.isEmpty { title = t }
            default:
                break
            }
        }

        let turnOpen = lastActivitySeq > lastEndSeq
        let state: SessionState
        var summary: String?
        if turnOpen {
            state = age > stallThreshold ? .needsYou : .running
            summary = turnAssistant ?? turnUser ?? title
        } else if lastEndSeq >= 0 {
            switch endKind {
            case "completed":
                state = age > doneWindow ? .idle : .done
                summary = turnAssistant ?? lastAssistant ?? title ?? turnUser
            case "error":
                state = age > doneWindow ? .idle : .done
                summary = (L10n.current == .zh ? "出错：" : "Error: ") + (endError ?? "")
            default:    // aborted / cancelled 等：用户自己停的，不打扰
                state = .idle
                summary = turnAssistant ?? title
            }
        } else {
            // 窗口里没看到任何 turn 事件（刚建的会话或极长的空档）
            state = age > stallThreshold ? .idle : .running
            summary = title ?? turnUser
        }

        let cwd = header?.cwd ?? Self.cwdFromSlug(url)
        return AgentSession(
            id: url.path,
            kind: kind,
            projectName: PathHelper.shortName(for: cwd),
            cwd: cwd,
            state: state,
            summary: oneLine(summary ?? "—"),
            changedAt: mtime,
            sourcePath: url.deletingLastPathComponent().path,
            deepLink: root.isDesktop && FileManager.default.fileExists(atPath: Self.desktopApp.path) ? Self.desktopApp : nil
        )
    }

    /// 目录名 `--Users-cinder-Desktop-My~0020Project--`：`/` 和 `-` 都成了 `-`，分不清；
    /// 只在首行 header 读不到时兜底取最后一段当项目名。
    static func cwdFromSlug(_ url: URL) -> String? {
        // …/sessions/<slug>/session-<id>/session.jsonl
        let slug = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        var s = slug
        if s.hasPrefix("--") { s.removeFirst(2) }
        if s.hasSuffix("--") { s.removeLast(2) }
        s = s.replacingOccurrences(of: "~0020", with: " ")
        return s.split(separator: "-").last.map(String.init)
    }
}

// MARK: - 文件读取（带缓存）

/// 解析结果按 (路径, mtime, 大小) 缓存：没变的文件不再解压，不然每秒一拍要起一个子进程。
final class DSHFiles: @unchecked Sendable {
    struct Header: Sendable { let id: String?; let cwd: String? }

    nonisolated(unsafe) private static var headers: [String: Header] = [:]
    nonisolated(unsafe) private static var tails: [String: (mtime: Date, lines: [String])] = [:]
    private static let lock = NSLock()

    static func header(of url: URL) -> Header? {
        lock.lock(); if let h = headers[url.path] { lock.unlock(); return h }; lock.unlock()
        let first: String?
        if url.pathExtension == "zstd" {
            first = ZstdDecoder.decodeFirstFrame(of: url)?.split(separator: "\n").first.map(String.init)
        } else {
            first = FileTail.firstLine(of: url)
        }
        guard let first, let obj = FileTail.json(first), obj["type"] as? String == "session" else { return nil }
        let h = Header(id: obj["id"] as? String, cwd: obj["cwd"] as? String)
        lock.lock(); headers[url.path] = h; lock.unlock()
        return h
    }

    static func tailLines(of url: URL, mtime: Date) -> [String] {
        lock.lock()
        if let c = tails[url.path], c.mtime == mtime { lock.unlock(); return c.lines }
        lock.unlock()
        let lines: [String]
        if url.pathExtension == "zstd" {
            lines = ZstdDecoder.decodeTail(of: url)?
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        } else {
            lines = FileTail.lines(of: url)
        }
        lock.lock(); tails[url.path] = (mtime, lines); lock.unlock()
        return lines
    }
}

// MARK: - zstd

/// 借外部程序解 zstd。顺序：Homebrew / 系统 `zstd` → DSH Desktop 自带的 Electron（Node 模式）。
/// 都没有就返回 nil，DSH 会话静默不显示。
enum ZstdDecoder {
    private static let magic = Data([0x28, 0xB5, 0x2F, 0xFD])

    private enum Backend { case cli(String), node(String) }
    nonisolated(unsafe) private static var resolved: Backend??   // 双层 optional：外层表示「查过没有」

    private static func backend() -> Backend? {
        if let r = resolved { return r }
        let fm = FileManager.default
        var found: Backend?
        for p in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"] where fm.isExecutableFile(atPath: p) {
            found = .cli(p); break
        }
        if found == nil {
            for p in ["/Applications/DSH Desktop.app/Contents/Frameworks/DSH Desktop Helper.app/Contents/MacOS/DSH Desktop Helper",
                      "/Applications/DSH Desktop.app/Contents/MacOS/DSH Desktop"] where fm.isExecutableFile(atPath: p) {
                found = .node(p); break
            }
        }
        resolved = .some(found)
        return found
    }

    /// Node 的 zstdDecompressSync 只解第一帧，得自己按 magic 切帧循环。
    private static let nodeScript = """
    const z=require("zlib"),M=Buffer.from([0x28,0xb5,0x2f,0xfd]),bs=[];
    process.stdin.on("data",d=>bs.push(d)).on("end",()=>{const b=Buffer.concat(bs);const out=[];let o=0;
    while(o<b.length){const a=b.indexOf(M,o);if(a<0)break;const n=b.indexOf(M,a+4);
    try{out.push(z.zstdDecompressSync(n<0?b.subarray(a):b.subarray(a,n)))}catch(e){}o=n<0?b.length:n}
    process.stdout.write(Buffer.concat(out))});
    """

    static func decode(_ data: Data) -> Data? {
        guard let backend = backend(), !data.isEmpty else { return nil }
        let proc = Process()
        var env = ProcessInfo.processInfo.environment
        switch backend {
        case .cli(let p):
            proc.executableURL = URL(fileURLWithPath: p)
            proc.arguments = ["-d", "-c", "-q"]
        case .node(let p):
            proc.executableURL = URL(fileURLWithPath: p)
            proc.arguments = ["-e", nodeScript]
            env["ELECTRON_RUN_AS_NODE"] = "1"
        }
        proc.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // 先异步灌输入再同步收输出，否则输入输出都超过管道缓冲时会互相等死
        DispatchQueue.global(qos: .utility).async {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
            try? inPipe.fileHandleForWriting.close()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return out.isEmpty ? nil : out
    }

    /// 只解末尾 maxBytes 内、从第一个完整帧开始的部分。帧对齐到行首，所以结果就是完整的若干行。
    static func decodeTail(of url: URL, maxBytes: Int = 256 * 1024) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        guard var data = try? h.readToEnd() else { return nil }
        if start > 0, let r = data.range(of: magic) { data = data.subdata(in: r.lowerBound..<data.endIndex) }
        guard let out = decode(data) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    /// 只解第一帧（首行 session header 在里面）。
    static func decodeFirstFrame(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard var data = try? h.read(upToCount: 64 * 1024) else { return nil }
        if let r = data.range(of: magic, in: 4..<data.endIndex) { data = data.subdata(in: 0..<r.lowerBound) }
        guard let out = decode(data) else { return nil }
        return String(data: out, encoding: .utf8)
    }
}
