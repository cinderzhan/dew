import Foundation

// MARK: - Agent 来源

/// 一个可接入的 Agent。新增 Agent 只需在这里加一个 case 并实现对应 adapter。
enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case codex
    case cursor
    case antigravity
    case dsh            // DeepSeek Harness：DSH Desktop 与 DSH CLI

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .cursor:     return "Cursor"
        case .antigravity: return "Antigravity"
        case .dsh:        return "DSH"
        }
    }
}

// MARK: - 会话状态（PRD 6.1 四态）

/// 优先级顺序即 case 顺序，`needsYou` 永远最高。
enum SessionState: Int, Codable, Comparable, Sendable {
    case needsYou = 0   // 等你介入：停下来等授权/等输入
    case running  = 1   // 进行中
    case done     = 2   // 已完成，未查看
    case idle     = 3   // 空闲/已查看

    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .needsYou: return L(.stateNeedsYou)
        case .running:  return L(.stateRunning)
        case .done:     return L(.stateDone)
        case .idle:     return L(.stateIdle)
        }
    }
}

// MARK: - 会话

struct AgentSession: Identifiable, Sendable {
    let id: String              // 稳定标识，一般用日志文件路径
    let kind: AgentKind
    let projectName: String     // 工作目录短名
    let cwd: String?
    let state: SessionState
    let summary: String         // 最后一条动作摘要，一行
    let changedAt: Date         // 进入当前状态的时间，用于算持续时长
    let sourcePath: String      // 日志文件路径，兜底用于在 Finder 定位
    /// 跳回 Agent 桌面端里这个会话的深链。没有就退回 Finder 定位。
    var deepLink: URL? = nil
    /// 这条深链的语义是「导入一份副本」而不是「聚焦已有会话」。
    /// 各家差别很实在：codex:// 和 cursor:// 是聚焦，claude://resume 是导入——
    /// 每跟一次就在对方 app 里多一条会话。默认不跟，见 AgentStore.reveal。
    var deepLinkCreatesNewSession: Bool = false
}

// MARK: - 定时任务

struct ScheduledTask: Identifiable, Sendable {
    let id: String
    let kind: AgentKind
    let name: String
    let scheduleText: String    // 人类可读，如「每天 10:00」
    let nextRun: Date?
    let enabled: Bool
    let sourcePath: String
    var deepLink: URL? = nil
}

// MARK: - 个人 To-do

enum TodoKind: String, Codable, CaseIterable, Sendable {
    case high     // 高优
    case daily    // 每日重复
    case normal   // 普通

    var label: String {
        switch self {
        case .high:   return L(.todoHigh)
        case .daily:  return L(.todoDaily)
        case .normal: return L(.todoNormal)
        }
    }
}

struct TodoItem: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    var title: String
    var kind: TodoKind
    var done: Bool = false
    var order: Int = 0
    /// 每日重复项最后一次完成的自然日（yyyy-MM-dd）。跨日后据此重置。
    var lastCompletedDay: String?
}

// MARK: - 折叠态信号

/// 折叠态只显示一个信号（PRD 5.1 铁律）。
struct CollapsedSignal: Sendable {
    let text: String
    let detail: String?
    let state: SessionState?
    /// 有高优未完成 to-do 时置位，折叠态附加一个极轻的标记
    let hasHighPriorityTodo: Bool
}
