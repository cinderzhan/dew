import Foundation
import Combine

/// 会话与定时任务的聚合层。UI 只跟它打交道，不认识任何具体 Agent。
@MainActor
final class AgentStore: ObservableObject {
    /// 供接口回调找回本实例。全局只有一个 store。
    nonisolated(unsafe) static weak var shared: AgentStore?

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var quotas: [AgentQuota] = []
    @Published private(set) var lastRefresh: Date = .distantPast

    // 「已完成」的两段式生命周期：
    //   这次打开面板 → 只**登记**为看过（seenThisOpen），列表里照常显示；
    //   下次再打开   → 上次登记的才真正隐藏（dismissed）。
    // 一段式（打开即隐藏）的问题是：下一拍刷新就把它们压没了，等于刚点开就消失。
    private var seenThisOpen: Set<String> = []
    private var dismissed: Set<String> = []
    private var viewingAgents = false
    /// 最近一次原始解析结果，改变可见性规则时用它立刻重算，不用等下一拍
    private var lastRaw: [AgentSession] = []

    private let adapters: [any AgentAdapter]
    private var timer: Timer?
    private var watcher: FileWatcher?
    private var isRefreshing = false
    private var pendingRefresh = false
    private var pendingForceQuota = false
    private var lastQuotaAt: Date = .distantPast

    /// 节拍器。文件事件负责「内容变了」，节拍器负责**不由文件驱动的时间态变化**
    /// ——例如「停超过 N 秒算等你介入」，这种转换没有任何文件会写。
    /// 一次刷新实测约 7ms，1 秒一次的开销可以忽略。
    private let tickInterval: TimeInterval = 1
    /// 额度要扫全量日志，比会话解析重，单独用慢节拍。
    private let quotaInterval: TimeInterval = 15

    // Antigravity 的 adapter 先不注册：会话正文加密、判不出「等你介入」、未经活数据验证。
    // 代码保留在 Adapters/AntigravityAdapter.swift，等能读到完整状态再接回来。
    init(adapters: [any AgentAdapter] = [ClaudeCodeAdapter(), CodexAdapter(), CursorAdapter(), DSHAdapter()]) {
        self.adapters = adapters
        refresh()

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 接口数据到手后立刻重算一次，否则 UI 会停在本地估算上
        ClaudeUsageAPI.onUpdate = {
            Task { @MainActor in
                AgentStore.shared?.refresh(forceQuota: true)
            }
        }
        AgentStore.shared = self

        // 文件一变就立刻刷新，不用等下一拍
        watcher = FileWatcher(paths: adapters.flatMap(\.watchPaths)) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh(forceQuota: Bool = false) {
        refreshSessions()
        if forceQuota || Date().timeIntervalSince(lastQuotaAt) >= quotaInterval {
            refreshQuota()
        }
    }

    /// 会话 + 定时任务。轻，几毫秒，1 秒一拍。
    ///
    /// **必须和额度分开跑。** 额度索引首次要扫全量日志，动辄几秒；
    /// 绑在一起时首屏会一直是「0 会话」，而且这几秒里所有后续刷新都在排队——
    /// 用户感受到的就是「响应慢」。
    private func refreshSessions() {
        guard !isRefreshing else { pendingRefresh = true; return }
        isRefreshing = true

        let adapters = self.adapters
        Task.detached(priority: .userInitiated) {
            var s: [AgentSession] = []
            var t: [ScheduledTask] = []
            for a in adapters {
                s.append(contentsOf: a.loadSessions())
                t.append(contentsOf: a.loadScheduledTasks())
            }
            let sessions = s, tasks = t
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(sessions: sessions, tasks: tasks)
                self.isRefreshing = false
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refreshSessions()
                }
            }
        }
    }

    /// 额度。重，单独节拍、单独任务、低优先级，绝不挡住会话刷新。
    private var isRefreshingQuota = false
    private func refreshQuota() {
        guard !isRefreshingQuota else { pendingForceQuota = true; return }
        isRefreshingQuota = true
        lastQuotaAt = Date()

        let adapters = self.adapters
        Task.detached(priority: .utility) {
            var q: [AgentQuota] = []
            for a in adapters {
                if let quota = a.loadQuota() { q.append(quota) }
            }
            let quotas = q
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.quotas = quotas
                self.isRefreshingQuota = false
                if self.pendingForceQuota {
                    self.pendingForceQuota = false
                    self.refreshQuota()
                }
            }
        }
    }

    private func apply(sessions raw: [AgentSession], tasks rawTasks: [ScheduledTask]) {
        lastRaw = raw
        // 正在看的时候新冒出来的「已完成」，也算这次看过了
        if viewingAgents {
            for s in raw where s.state == .done { seenThisOpen.insert(ackKey(s)) }
        }
        // 上一次打开时看过的「已完成」降级为空闲
        let adjusted = raw.map { s -> AgentSession in
            guard s.state == .done, dismissed.contains(ackKey(s)) else { return s }
            return AgentSession(id: s.id, kind: s.kind, projectName: s.projectName, cwd: s.cwd,
                                state: .idle, summary: s.summary, changedAt: s.changedAt,
                                sourcePath: s.sourcePath)
        }
        sessions = adjusted.sorted {
            $0.state == $1.state ? $0.changedAt > $1.changedAt : $0.state < $1.state
        }
        tasks = rawTasks
            .filter(\.enabled)
            .sorted { (a, b) in
                switch (a.nextRun, b.nextRun) {
                case let (x?, y?): return x < y
                case (nil, _):     return false
                case (_, nil):     return true
                }
            }
        lastRefresh = Date()
    }

    private func ackKey(_ s: AgentSession) -> String {
        "\(s.id)@\(Int(s.changedAt.timeIntervalSince1970))"
    }

    /// Agents 列表进入视野。每次「打开面板」只算一次，面板内来回切 tab 不重复计。
    func beginViewingAgents() {
        guard !viewingAgents else { return }
        viewingAgents = true
        // 上次看过的这次隐藏；这次看到的登记下来留给下次
        dismissed.formUnion(seenThisOpen)
        seenThisOpen = Set(lastRaw.filter { $0.state == .done }.map(ackKey))
        apply(sessions: lastRaw, tasks: tasks)
    }

    /// 面板收起
    func endViewing() {
        viewingAgents = false
    }

    // MARK: - 派生

    var visibleSessions: [AgentSession] { sessions.filter { $0.state != .idle } }

    func sessions(in state: SessionState) -> [AgentSession] {
        sessions.filter { $0.state == state }
    }

    /// 折叠态只显示一个信号（PRD 5.1）。优先级：等你介入 > 已完成 > 进行中 > 全部空闲。
    func collapsedSignal(hasHighPriorityTodo: Bool) -> CollapsedSignal {
        let needs = sessions(in: .needsYou)
        if !needs.isEmpty {
            return CollapsedSignal(text: L(.sigNeedsYou, needs.count),
                                   detail: needs.first?.projectName,
                                   state: .needsYou,
                                   hasHighPriorityTodo: hasHighPriorityTodo)
        }
        let done = sessions(in: .done)
        if !done.isEmpty {
            return CollapsedSignal(text: L(.sigDone, done.count),
                                   detail: done.first?.projectName,
                                   state: .done,
                                   hasHighPriorityTodo: hasHighPriorityTodo)
        }
        let running = sessions(in: .running)
        if !running.isEmpty {
            return CollapsedSignal(text: L(.sigRunning, running.count),
                                   detail: running.first?.projectName,
                                   state: .running,
                                   hasHighPriorityTodo: hasHighPriorityTodo)
        }
        let upcoming = tasks.first
        return CollapsedSignal(text: L(.sigAllIdle),
                               detail: upcoming.map { RelTime.untilText($0.nextRun) },
                               state: nil,
                               hasHighPriorityTodo: hasHighPriorityTodo)
    }

    /// 点击会话：优先跳回 Agent 桌面端里的那个会话；对应 app 没装或深链打不开，再退回 Finder 定位日志。
    ///
    /// 「导入型」深链（Claude 的 claude://resume）默认不跟——它不是聚焦已有会话，
    /// 而是在对方 app 里新建一条无标题会话，点几次就堆几条。用户在设置里显式打开才跟。
    func reveal(_ session: AgentSession) {
        guard let link = session.deepLink else {
            NSWorkspaceReveal.reveal(path: session.sourcePath)
            return
        }

        // Codex / Cursor / DSH 的深链都是聚焦语义，直接跟。
        guard link.scheme == "claude" else {
            NSWorkspaceReveal.open(link, fallbackPath: session.sourcePath)
            return
        }

        // Claude 优先走聚焦路由。它在部分版本里被功能开关关着——点了毫无反应，
        // 只在 Claude 自己的日志里留一行——所以跟完回头确认，被挡就退到导入。
        if !session.deepLinkCreatesNewSession, !ClaudeFocusGate.isKnownOff() {
            ClaudeFocusGate.open(link) { [weak self] in
                Task { @MainActor in self?.importOrReveal(session) }
            }
            return
        }
        importOrReveal(session)
    }

    /// 最后两级退路：导入一份（需用户开启，且同一条会话只导入一次），否则 Finder 定位。
    private func importOrReveal(_ session: AgentSession) {
        guard let link = session.importDeepLink ?? session.deepLink,
              AppSettings.shared.importingDeepLinksEnabled,
              DeepLinkImportLedger.claimFirstImport(of: session.id) else {
            NSWorkspaceReveal.reveal(path: session.sourcePath)
            return
        }
        NSWorkspaceReveal.open(link, fallbackPath: session.sourcePath)
    }

    func reveal(_ task: ScheduledTask) {
        NSWorkspaceReveal.open(task.deepLink, fallbackPath: task.sourcePath)
    }
}
