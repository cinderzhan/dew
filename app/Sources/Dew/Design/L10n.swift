import Foundation

/// 界面语言。
enum Language: String, CaseIterable, Codable, Sendable {
    case zh, en

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    /// 跟随系统的默认值
    static var systemDefault: Language {
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? .zh : .en
    }
}

/// 所有面向用户的文案都从这里出。
///
/// 不用 .strings 文件，原因有两个：我们不走 Xcode 工程，资源打包要自己拼；
/// 以及文案总量就一百来条，一张表更容易一眼看全、顺手改两种语言。
///
/// `current` 是 nonisolated 的，因为 adapter 在后台线程拼摘要与时间文本。
enum L10n {
    nonisolated(unsafe) static var current: Language = .systemDefault

    static func t(_ key: Key) -> String {
        let pair = table[key] ?? (key.rawValue, key.rawValue)
        return current == .zh ? pair.0 : pair.1
    }

    /// 带一个数字的模板，`#` 是占位
    static func t(_ key: Key, _ n: Int) -> String {
        t(key).replacingOccurrences(of: "#", with: String(n))
    }

    static func t(_ key: Key, _ s: String) -> String {
        t(key).replacingOccurrences(of: "#", with: s)
    }

    enum Key: String {
        // tabs
        case tabAgents, tabTodo, tabUsage
        // session states
        case stateNeedsYou, stateRunning, stateDone, stateIdle
        // groups
        case groupScheduled, moreDone
        // collapsed signal
        case sigNeedsYou, sigDone, sigRunning, sigAllIdle
        // summaries
        case waitingApproval
        // empty hints
        case emptyAgents, emptyTodo, emptyUsage
        // todo
        case todoHigh, todoDaily, todoNormal
        case todoHighShort, todoDailyShort, todoNormalShort
        case todoPlaceholder, moveTo, delete, edit
        case seedDaily1, seedDaily2
        // footer / chrome
        case sessionsCount, todosCount, settings, collapse
        // settings pane
        case opacity, opacityHint, language
        case claudeUsageToggle, claudeUsageExplain, claudeUsageOffHint
        case deepLinkToggle, deepLinkExplain
        // menu bar
        case menuToggle, menuResetPosition, menuQuit
        // schedule humanize
        case scheduled, everyDay, everyDayAt, everyHour, everyWeek, everyWeekOn, weekdaysAt, everyMonthOn
        case wdSun, wdMon, wdTue, wdWed, wdThu, wdFri, wdSat
        // relative time
        case past, rightNow, tomorrow, daysLater, hoursLater, minutesLater
        case secondsAgo, minutesAgo, hoursAgo, daysAgo
        // usage
        case usageLocalNote, usageOutput
        case usageErrExpired, usageErrNoCredential, usageErrHTTP, usageErrNetwork
        case resetDone, resetInHM, resetInM, resetAt
        case winLast5h, winLast7d, winTotal, winQuota, winWeek, winToday, win5h, win1h, winNDays, winNHours, winNMinutes
        case winSession, winWeeklyAll, winWeeklyScoped, winWeeklySingle
    }

    private static let table: [Key: (String, String)] = [
        .tabAgents: ("Agents", "Agents"),
        .tabTodo: ("待办", "To-do"),
        .tabUsage: ("用量", "Usage"),

        .stateNeedsYou: ("等你介入", "Needs you"),
        .stateRunning: ("进行中", "Running"),
        .stateDone: ("已完成", "Done"),
        .stateIdle: ("空闲", "Idle"),

        .groupScheduled: ("定时任务", "Scheduled"),
        .moreDone: ("还有 # 项已完成", "# more done"),

        .sigNeedsYou: ("# 个等你介入", "# need you"),
        .sigDone: ("# 个已完成", "# done"),
        .sigRunning: ("# 个进行中", "# running"),
        .sigAllIdle: ("全部空闲", "All idle"),

        .waitingApproval: ("等待授权：#", "Waiting for approval: #"),

        .emptyAgents: ("没有活跃会话。开一个 Claude Code 或 Codex 就会出现在这里。",
                       "No active sessions. Start Claude Code or Codex and it will show up here."),
        .emptyTodo: ("还没有待办。在上面输入，回车添加。", "Nothing yet. Type above and press Return."),
        .emptyUsage: ("还没读到用量。开一个会话后就会出现。", "No usage yet. It appears after your first session."),

        .todoHigh: ("高优", "High priority"),
        .todoDaily: ("每日重复", "Daily"),
        .todoNormal: ("普通", "Normal"),
        .todoHighShort: ("高优", "High"),
        .todoDailyShort: ("每日", "Daily"),
        .todoNormalShort: ("普通", "Normal"),
        .todoPlaceholder: ("加一条待办…", "Add a to-do…"),
        .moveTo: ("移到「#」", "Move to #"),
        .delete: ("删除", "Delete"),
        .seedDaily1: ("把今天的进展记一笔", "Write down today's progress"),
        .seedDaily2: ("清空收件箱", "Clear the inbox"),

        .sessionsCount: ("# 个会话", "# sessions"),
        .todosCount: ("# 项待办", "# to-dos"),
        .settings: ("设置", "Settings"),
        .collapse: ("收起", "Collapse"),

        .opacity: ("透明度", "Opacity"),
        .opacityHint: ("往低拧是从毛玻璃滑向液态玻璃，不会完全透明。",
                       "Lower slides from frosted toward liquid glass. It never goes fully clear."),
        .language: ("语言", "Language"),
        .claudeUsageToggle: ("读取 Claude 官方额度", "Read Claude's official usage"),
        .claudeUsageExplain: ("开启后会读取 Claude Code 存在钥匙串里的登录凭据，向 api.anthropic.com 查询限额窗口。凭据只在内存中，不落盘、不记录、不发往其他地方。这是一个未公开接口，可能随 Claude 更新失效。",
                              "When on, reads the Claude Code sign-in credential from Keychain and queries api.anthropic.com for your rate-limit windows. The credential stays in memory only — never written, logged, or sent elsewhere. This is an undocumented endpoint and may break when Claude updates."),
        .claudeUsageOffHint: ("Claude 的额度百分比需要在设置里打开「读取 Claude 官方额度」。", "Turn on \"Read Claude's official usage\" in Settings to see Claude's limit percentages."),

        .deepLinkToggle: ("聚焦不可用时改用导入跳转", "Fall back to importing when focus is unavailable"),
        .deepLinkExplain: ("点击 Claude 会话时优先「聚焦」到桌面端已有的那条对话，不新建任何东西。但这条路由在部分 Claude 版本里被官方的功能开关关着（Dew 会自动识别并退回）。退回之后，开着此项就改用「导入」跳过去——同一条会话只导入一次，之后再点会在访达里定位它的日志。关掉此项则直接定位日志。",
                           "Clicking a Claude session focuses the conversation the desktop app already has, creating nothing. That route is disabled by a feature flag in some Claude versions (Dew detects this and backs off). When it does, this switch decides what happens next: import the session to jump to it — at most once per session, later clicks reveal its log in Finder — or, with this off, go straight to the log."),

        .usageErrExpired: ("读不到 Claude 官方额度：登录凭据已过期。在终端跑一次 claude auth login，之后会自动恢复。",
                           "Claude's official usage is unavailable: the sign-in credential has expired. Run `claude auth login` in a terminal and it recovers on its own."),
        .usageErrNoCredential: ("读不到 Claude 官方额度：钥匙串里找不到 Claude Code 的登录凭据，或访问被拒绝。",
                                "Claude's official usage is unavailable: no Claude Code credential in the Keychain, or access was denied."),
        .usageErrHTTP: ("读不到 Claude 官方额度：接口返回 HTTP #。下面是本地日志累计的用量。",
                        "Claude's official usage is unavailable: the endpoint returned HTTP #. Figures below are counted from local logs."),
        .usageErrNetwork: ("读不到 Claude 官方额度：#。下面是本地日志累计的用量。",
                           "Claude's official usage is unavailable: #. Figures below are counted from local logs."),

        .menuToggle: ("显示 / 收起", "Show / Collapse"),
        .menuResetPosition: ("回到默认位置", "Reset position"),
        .menuQuit: ("退出", "Quit"),

        .scheduled: ("定时", "Scheduled"),
        .everyDay: ("每天", "Daily"),
        .everyDayAt: ("每天 #", "Daily #"),
        .everyHour: ("每小时", "Hourly"),
        .everyWeek: ("每周", "Weekly"),
        .everyWeekOn: ("每周#", "Every #"),
        .weekdaysAt: ("工作日 #", "Weekdays #"),
        .everyMonthOn: ("每月 # 日", "Monthly on day #"),
        .wdSun: ("日", "Sun"), .wdMon: ("一", "Mon"), .wdTue: ("二", "Tue"), .wdWed: ("三", "Wed"),
        .wdThu: ("四", "Thu"), .wdFri: ("五", "Fri"), .wdSat: ("六", "Sat"),

        .past: ("已过", "Passed"),
        .rightNow: ("马上", "Now"),
        .tomorrow: ("明天", "Tomorrow"),
        .daysLater: ("# 天后", "in # d"),
        .hoursLater: ("# 小时后", "in # h"),
        .minutesLater: ("# 分钟后", "in # min"),
        .secondsAgo: ("# 秒", "#s"),
        .minutesAgo: ("# 分钟", "# min"),
        .hoursAgo: ("# 小时", "# h"),
        .daysAgo: ("# 天", "# d"),

        .usageLocalNote: ("没有进度条的项，是本地日志累加出来的用量，不是剩余额度。",
                          "Rows without a bar are totals summed from local logs, not remaining quota."),
        .usageOutput: ("输出 #", "Output #"),
        .resetDone: ("已重置", "Reset"),
        .resetInHM: ("# 后重置", "Resets in #"),
        .resetInM: ("# 分后重置", "Resets in # min"),
        .resetAt: ("# 重置", "Resets #"),
        .winLast5h: ("近 5 小时", "Last 5 h"),
        .winLast7d: ("近 7 天", "Last 7 d"),
        .winTotal: ("累计", "Total"),
        .winQuota: ("额度", "Quota"),
        .winWeek: ("本周", "This week"),
        .winToday: ("今日", "Today"),
        .win5h: ("5 小时", "5 hours"),
        .win1h: ("1 小时", "1 hour"),
        .winNDays: ("# 天", "# days"),
        .winNHours: ("# 小时", "# hours"),
        .winNMinutes: ("# 分钟", "# min"),
        .winSession: ("5 小时", "5 hours"),
        .winWeeklyAll: ("本周 · 全部模型", "Week · all models"),
        .winWeeklyScoped: ("本周 · #", "Week · #"),
        .winWeeklySingle: ("本周 · 单模型", "Week · one model"),
    ]
}

/// 短写
@inline(__always) func L(_ key: L10n.Key) -> String { L10n.t(key) }
@inline(__always) func L(_ key: L10n.Key, _ n: Int) -> String { L10n.t(key, n) }
@inline(__always) func L(_ key: L10n.Key, _ s: String) -> String { L10n.t(key, s) }
