import Foundation

/// 一个限额窗口的读数。
struct QuotaWindow: Identifiable, Sendable {
    let id = UUID()
    let label: String          // 「本周」「近 5 小时」
    /// 已用百分比。只有真实额度接口才有；本地估算一律为 nil。
    let usedPercent: Double?
    /// 窗口重置时间。同上，估算没有。
    let resetsAt: Date?
    /// 该窗口内的 token 总量（含缓存读取）
    let totalTokens: Int?
    /// 该窗口内的输出 token
    let outputTokens: Int?
    /// 接口给的告警等级（normal / warning / …）。本地估算为 nil。
    var severity: String? = nil
    /// 接口标记的「当前正在消耗的那条限额」
    var isActive: Bool = false

    /// 是否该用信号色。接口说不正常时就信它，否则按 85% 兜底。
    var isCritical: Bool {
        if let severity, severity.lowercased() != "normal" { return true }
        return (usedPercent ?? 0) >= 85
    }
}

/// 一个 Agent 的用量读数。
struct AgentQuota: Identifiable, Sendable {
    var id: AgentKind { kind }
    let kind: AgentKind
    /// 套餐名，如 plus。拿不到就是 nil。
    let planType: String?
    let windows: [QuotaWindow]
    /// true 表示这是**本地日志累计的用量**，不是官方的剩余额度。
    /// 界面上必须把这个区别讲清楚，不能让人误以为是额度百分比。
    let isLocalEstimate: Bool
    /// 数据取自哪一刻
    let sampledAt: Date?
}

extension Int {
    /// 8296127 → "8.3M"
    var compactTokens: String {
        let n = Double(self)
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", n / 1_000) }
        return "\(self)"
    }
}
