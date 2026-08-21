import Foundation

/// 演示模式（`DEW_DEMO=1`）的假数据源。用于截图、录屏、给别人看界面。
///
/// 不读任何 Agent 目录，也不参与文件监听；每个 AgentKind 一个实例，
/// 和真实 adapter 走同一条 store → UI 的路，UI 层完全感知不到区别。
/// 时间都相对于实例创建时刻算，所以「进行中 12 秒」会自己往上走，看着像活的。
struct DemoAdapter: AgentAdapter {
    let kind: AgentKind
    private let born = Date()

    var watchPaths: [URL] { [] }

    static var all: [any AgentAdapter] {
        [DemoAdapter(kind: .claudeCode), DemoAdapter(kind: .codex), DemoAdapter(kind: .cursor)]
    }

    private func t(_ zh: String, _ en: String) -> String { L10n.current == .zh ? zh : en }
    private func ago(_ s: TimeInterval) -> Date { born.addingTimeInterval(-s) }

    private func session(_ project: String, _ state: SessionState, _ zh: String, _ en: String, _ agoSec: TimeInterval) -> AgentSession {
        AgentSession(id: "demo/\(kind.rawValue)/\(project)", kind: kind,
                     projectName: project, cwd: "~/Projects/\(project)",
                     state: state, summary: t(zh, en), changedAt: ago(agoSec), sourcePath: "")
    }

    func loadSessions() -> [AgentSession] {
        switch kind {
        case .claudeCode:
            return [
                session("web-app", .needsYou,
                        "是否允许运行 `npm run build`？", "Allow running `npm run build`?", 95),
                session("billing-service", .running,
                        "正在补齐 invoice 模块的单元测试", "Adding unit tests for the invoice module", 12),
                session("data-pipeline", .done,
                        "已修复时区 bug：3 个文件，测试全绿", "Fixed the timezone bug: 3 files, tests green", 28 * 60),
            ]
        case .codex:
            return [
                session("api-server", .running,
                        "重构鉴权中间件，顺手收掉两个 TODO", "Refactoring auth middleware, closing two TODOs", 40),
                session("landing-page", .done,
                        "首屏文案改好了，见 docs/copy.md", "Hero copy updated — see docs/copy.md", 66 * 60),
            ]
        case .cursor:
            return [
                session("docs-site", .done,
                        "部署文档已更新到 v0.2", "Deploy docs updated for v0.2", 130 * 60),
            ]
        case .antigravity:
            return []
        }
    }

    func loadScheduledTasks() -> [ScheduledTask] {
        let now = Date()
        func rr(_ name: String, _ rrule: String) -> ScheduledTask {
            ScheduledTask(id: "demo/task/\(name)", kind: kind, name: name,
                          scheduleText: RRule.humanize(rrule), nextRun: RRule.nextRun(after: now, rrule: rrule),
                          enabled: true, sourcePath: "")
        }
        func cron(_ name: String, _ expr: String) -> ScheduledTask {
            ScheduledTask(id: "demo/task/\(name)", kind: kind, name: name,
                          scheduleText: Cron.humanize(expr), nextRun: Cron.nextRun(after: now, expression: expr),
                          enabled: true, sourcePath: "")
        }
        switch kind {
        case .codex:
            return [
                rr(t("每日工作日报总结", "Daily work summary"), "RRULE:FREQ=DAILY;BYHOUR=22;BYMINUTE=0"),
                rr(t("竞品动态摘要", "Competitor digest"), "RRULE:FREQ=DAILY;BYHOUR=10;BYMINUTE=0"),
            ]
        case .claudeCode:
            return [cron(t("依赖安全扫描", "Dependency security scan"), "0 9 * * 1")]
        default:
            return []
        }
    }

    func loadQuota() -> AgentQuota? {
        let now = Date()
        switch kind {
        case .claudeCode:
            return AgentQuota(kind: kind, planType: "max", windows: [
                QuotaWindow(label: L(.win5h), usedPercent: 61, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60),
                            totalTokens: 2_480_000, outputTokens: 96_000, severity: "normal", isActive: true),
                QuotaWindow(label: L(.winWeek), usedPercent: 27, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600),
                            totalTokens: 11_300_000, outputTokens: 410_000, severity: "normal"),
            ], isLocalEstimate: false, sampledAt: now)
        case .codex:
            return AgentQuota(kind: kind, planType: "plus", windows: [
                QuotaWindow(label: L(.win5h), usedPercent: 42, resetsAt: now.addingTimeInterval(3 * 3600 + 40 * 60),
                            totalTokens: 1_120_000, outputTokens: 58_000),
                QuotaWindow(label: L(.winWeek), usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86400),
                            totalTokens: nil, outputTokens: nil),
            ], isLocalEstimate: false, sampledAt: now)
        default:
            return nil
        }
    }
}
