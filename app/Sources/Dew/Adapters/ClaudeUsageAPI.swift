import Foundation
import Security

/// Claude Code 的限额读取。
///
/// 为什么必须走接口：5 小时 / 整周的百分比**不落在任何可持续读取的本地文件里**。
/// 已排查过日志的 error.rateLimits（仅报错时出现且为 null）、
/// audit.jsonl 的 rate_limit_event（仅接近限额时写、且早已过期）、
/// ~/.claude.json（只有套餐等级）。接口地址取自 Claude Code 自身安装包。
///
/// 凭据处理原则：
/// - token 只在本进程内存中存在，绝不写日志、绝不落盘
/// - 只发往 api.anthropic.com，即该 token 本来的归属方
/// - 读 Keychain 时 macOS 会向用户确认
enum ClaudeUsageAPI {

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    // MARK: - Keychain

    /// 凭据的进程内缓存：钥匙串授权没记住（自签名 + 分区列表）时，每读一次就弹一次密码框。
    nonisolated(unsafe) private static var cachedCredential: (token: String, expiresAt: Date?)?
    nonisolated(unsafe) private static var credentialReadAt: Date = .distantPast
    /// 凭据已过期时，回钥匙串复查的间隔。
    /// 既要让用户跑完 `claude auth login` 之后能自动恢复，又不能每两分钟弹一次密码框。
    private static let expiredRecheckInterval: TimeInterval = 300

    private static func credential() -> (token: String, expiresAt: Date?)? {
        lock.lock()
        if let c = cachedCredential {
            let usable = c.expiresAt.map { $0 > Date().addingTimeInterval(60) } ?? true
            if usable || Date().timeIntervalSince(credentialReadAt) < expiredRecheckInterval {
                lock.unlock(); return c
            }
        }
        lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if ProcessInfo.processInfo.environment["DEW_DEBUG"] != nil {
            NSLog("[gb] Keychain 查询 OSStatus=%d", Int(status))
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }

        let tier = (oauth["rateLimitTier"] as? String) ?? (oauth["subscriptionType"] as? String)
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        lock.lock()
        cachedPlan = tier.flatMap(prettyTier)
        cachedCredential = (token, expiresAt)
        credentialReadAt = Date()
        lock.unlock()

        return (token, expiresAt)
    }

    /// "default_claude_max_5x" → "Max 5x"
    static func prettyTier(_ raw: String) -> String? {
        var t = raw.replacingOccurrences(of: "default_", with: "")
                   .replacingOccurrences(of: "claude_", with: "")
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: "_").map(String.init)
        guard let head = parts.first else { return nil }
        let rest = parts.dropFirst().joined(separator: " ")
        return rest.isEmpty ? head.capitalized : "\(head.capitalized) \(rest)"
    }

    // MARK: - 拉取

    /// 结果缓存，避免每次刷新都打接口
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [QuotaWindow]?
    nonisolated(unsafe) private static var cachedAt: Date = .distantPast
    nonisolated(unsafe) private static var inFlight = false
    /// 拿不到官方额度的原因。做成类型而不是拼好的字符串，界面才能本地化，
    /// 也才分得清「凭据过期」（用户跑一条命令就能修）和「接口挂了」（只能等）。
    enum Failure: Sendable, Equatable {
        case noCredential
        case credentialExpired
        case http(Int)
        case network(String)
    }

    nonisolated(unsafe) private static var lastError: Failure?

    static let refreshInterval: TimeInterval = 120

    /// 由 AppSettings 驱动。关着的时候：不碰 Keychain、不发请求、current() 返回 nil。
    nonisolated(unsafe) static var isEnabled = false

    /// 拿到新数据时回调。
    /// 没有它的话时序永远错位：loadQuota 先发请求、再立刻读缓存，
    /// 第一次必然读到空而回落到本地估算，之后的常规刷新又不重算额度。
    nonisolated(unsafe) static var onUpdate: (@Sendable () -> Void)?

    /// 套餐等级。顺带从 Keychain 那份凭据里取——它自带 rateLimitTier，
    /// 比 ~/.claude.json 可靠：后者在重新登录后会被清空，要等 profile 重新拉取才回填。
    nonisolated(unsafe) private static var cachedPlan: String?
    static func planLabel() -> String? {
        lock.lock(); defer { lock.unlock() }
        return cachedPlan
    }

    static func current() -> [QuotaWindow]? {
        guard isEnabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    static func currentFailure() -> Failure? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    /// 到期就在后台拉一次。调用方无需等待，下一拍自然会读到新值。
    static func refreshIfNeeded(force: Bool = false) {
        guard isEnabled else { return }
        lock.lock()
        let due = force || Date().timeIntervalSince(cachedAt) >= refreshInterval
        guard due, !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()

        guard let cred = credential() else {
            finish(windows: nil, failure: .noCredential)
            return
        }
        // 已经过期就不必去撞那个必然的 401。凭据只有 `claude` CLI 自己会续期。
        if let exp = cred.expiresAt, exp <= Date() {
            finish(windows: nil, failure: .credentialExpired)
            return
        }
        let token = cred.token

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                finish(windows: nil, failure: .network(error.localizedDescription))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                if code == 401 {    // 凭据失效：丢掉缓存，下一轮重读钥匙串（claude CLI 续期后就能自愈）
                    lock.lock(); cachedCredential = nil; lock.unlock()
                }
                finish(windows: nil, failure: code == 401 ? .credentialExpired : .http(code))
                return
            }

            // 开发期：把原始结构打出来，好照着写解析。
            // 响应体里只有用量数据，不含任何凭据。
            if ProcessInfo.processInfo.environment["DEW_DEBUG"] != nil,
               let raw = String(data: data, encoding: .utf8) {
                NSLog("[gb] /api/oauth/usage 原始返回: %@", String(raw.prefix(2000)))
            }

            let obj = try? JSONSerialization.jsonObject(with: data)
            finish(windows: parse(obj), failure: nil)
        }.resume()
    }

    private static func finish(windows: [QuotaWindow]?, failure: Failure?) {
        if ProcessInfo.processInfo.environment["DEW_DEBUG"] != nil {
            NSLog("[gb] usage 拉取结束: windows=%ld error=%@",
                  windows?.count ?? -1, String(describing: failure ?? .noCredential))
        }
        lock.lock()
        if let windows, !windows.isEmpty { cached = windows }
        lastError = failure
        cachedAt = Date()
        inFlight = false
        let gotData = windows?.isEmpty == false
        lock.unlock()

        if gotData { onUpdate?() }
    }

    // MARK: - 解析
    //
    // 返回体里同时有两套数据：顶层的 five_hour / seven_day / 一堆内部代号，
    // 以及一个 limits 数组。**用 limits**——它就是 Claude 自己 /usage 界面用的那份，
    // kind + group + scope 三个字段足以还原它的分组标签，而且不会混进
    // nimbus_quill 这类值为 0 的内部条目。
    //
    // 顶层字段留作兜底：万一哪天 limits 没了，还能退回去认 utilization。

    static func parse(_ obj: Any?) -> [QuotaWindow]? {
        guard let root = obj as? [String: Any] else { return nil }
        if let limits = root["limits"] as? [[String: Any]] {
            let windows = limits.compactMap(window(fromLimit:))
            if !windows.isEmpty { return windows }
        }
        return legacyParse(root)
    }

    private static func window(fromLimit dict: [String: Any]) -> QuotaWindow? {
        guard let percent = numeric(dict["percent"]) else { return nil }
        let kind = (dict["kind"] as? String) ?? ""

        // weekly_scoped 的具体对象在 scope 里，比如 scope.model.display_name = "Fable"
        let scopeName: String? = {
            guard let scope = dict["scope"] as? [String: Any] else { return nil }
            if let model = scope["model"] as? [String: Any],
               let name = model["display_name"] as? String, !name.isEmpty { return name }
            if let surface = scope["surface"] as? [String: Any],
               let name = surface["display_name"] as? String, !name.isEmpty { return name }
            return nil
        }()

        let label: String
        switch kind {
        case "session":        label = L(.winSession)
        case "weekly_all":     label = L(.winWeeklyAll)
        case "weekly_scoped":  label = scopeName.map { L(.winWeeklyScoped, $0) } ?? L(.winWeeklySingle)
        default:
            let pretty = kind.replacingOccurrences(of: "_", with: " ")
            label = scopeName.map { "\(pretty) · \($0)" } ?? (pretty.isEmpty ? L(.winQuota) : pretty)
        }

        return QuotaWindow(label: label,
                           usedPercent: percent,
                           resetsAt: date(dict["resets_at"]),
                           totalTokens: nil,
                           outputTokens: nil,
                           severity: dict["severity"] as? String,
                           isActive: (dict["is_active"] as? Bool) ?? false)
    }

    /// 兜底：顶层的 five_hour / seven_day。只认白名单，避免把内部代号当额度显示。
    private static func legacyParse(_ root: [String: Any]) -> [QuotaWindow]? {
        let known: [(key: String, label: String)] = [
            ("five_hour", L(.winSession)),
            ("seven_day", L(.winWeeklyAll)),
            ("seven_day_opus", L(.winWeeklyScoped, "Opus")),
            ("seven_day_sonnet", L(.winWeeklyScoped, "Sonnet")),
        ]
        let windows: [QuotaWindow] = known.compactMap { entry in
            guard let d = root[entry.key] as? [String: Any],
                  let pct = numeric(d["utilization"]) else { return nil }
            return QuotaWindow(label: entry.label, usedPercent: pct,
                               resetsAt: date(d["resets_at"]),
                               totalTokens: nil, outputTokens: nil)
        }
        return windows.isEmpty ? nil : windows
    }

    private static func numeric(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func date(_ v: Any?) -> Date? {
        if let d = v as? Double { return Date(timeIntervalSince1970: d) }
        if let i = v as? Int { return Date(timeIntervalSince1970: Double(i)) }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
