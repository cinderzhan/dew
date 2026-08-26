import Foundation
import Combine

/// 个人 to-do。纯本地单文件，无账号无云（PRD 7.3）。
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []

    private let fileURL: URL
    /// 演示模式：内存里一份示例数据，**不读不写** todos.json。
    private let isDemo: Bool
    private let defaults: UserDefaults
    private var dayCheckTimer: Timer?

    /// `directory` 与 `defaults` 可注入，只为了测试能在临时目录里跑。
    /// 别小看这个口子：`Application Support` 的路径**不受 HOME 环境变量影响**，
    /// 想靠改 HOME 隔离测试是行不通的——只会写进用户的真实数据。
    init(demo: Bool = false, directory: URL? = nil, defaults: UserDefaults = .standard) {
        isDemo = demo
        self.defaults = defaults
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Dew")
        fileURL = dir.appending(path: "todos.json")

        if demo {
            items = Self.demoItems()
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            load()
        }
        rollOverIfNeeded()

        // 跨自然日时把每日重复项重置为未完成
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rollOverIfNeeded() }
        }
        RunLoop.main.add(t, forMode: .common)
        dayCheckTimer = t
    }

    deinit { dayCheckTimer?.invalidate() }

    // MARK: - 查询

    func items(of kind: TodoKind) -> [TodoItem] {
        items.filter { $0.kind == kind }.sorted { $0.order < $1.order }
    }

    var hasUnfinishedHighPriority: Bool {
        items.contains { $0.kind == .high && !$0.done }
    }

    var openCount: Int { items.filter { !$0.done }.count }

    // MARK: - 变更

    func add(_ title: String, kind: TodoKind) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let nextOrder = (items.filter { $0.kind == kind }.map(\.order).max() ?? -1) + 1
        items.append(TodoItem(title: t, kind: kind, order: nextOrder))
        save()
    }

    func toggle(_ item: TodoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].done.toggle()
        items[i].lastCompletedDay = items[i].done ? Self.today() : nil
        save()
    }

    func remove(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// 就地改标题。空白视为「没改」——按回车不该把一条待办变成空行。
    func rename(_ item: TodoItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = items.firstIndex(where: { $0.id == item.id }),
              items[i].title != trimmed else { return }
        items[i].title = trimmed
        save()
    }

    func move(_ item: TodoItem, to kind: TodoKind) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].kind = kind
        items[i].order = (items.filter { $0.kind == kind }.map(\.order).max() ?? -1) + 1
        save()
    }

    // MARK: - 跨自然日的清理

    /// 每分钟检查一次，跨过零点时把「昨天的完成」处理掉。两类项处理不同：
    ///
    /// - **每日重复**：取消勾选、留在原地（它的意义就是明天再做一遍）
    /// - **高优 / 普通**：完成即用完，隔天直接删除——昨天的成就不该占今天的视觉
    ///
    /// **首次运行只补戳、不清理。** 否则用户升级上来的那一刻，几天前完成的项会集体消失，
    /// 而这条规则是他们升级之后才知道的。规则从今天开始生效，不追溯。
    /// `lastRolloverDay` 兼作「有没有跑过」的标记：没有值即首次。
    private func rollOverIfNeeded() {
        let today = Self.today()
        let firstRun = defaults.string(forKey: Keys.lastRolloverDay) == nil
        var changed = false

        // 会被删除的那两类才需要日期戳。首次运行时全部补成今天；
        // 平时只补没有戳的（手改过文件、或更老版本写入的项）。
        for i in items.indices where items[i].kind != .daily && items[i].done {
            guard firstRun || items[i].lastCompletedDay == nil else { continue }
            if items[i].lastCompletedDay != today {
                items[i].lastCompletedDay = today
                changed = true
            }
        }

        // 每日重复：跨日取消勾选。首次运行也照常——它本来就是这个语义，不是新规则。
        for i in items.indices where items[i].kind == .daily {
            if items[i].done, items[i].lastCompletedDay != today {
                items[i].done = false
                changed = true
            }
        }

        let before = items.count
        items.removeAll { $0.kind != .daily && $0.done && $0.lastCompletedDay != today }
        if items.count != before { changed = true }

        if !isDemo { defaults.set(today, forKey: Keys.lastRolloverDay) }
        if changed { save() }
    }

    private enum Keys {
        /// 最后一次跨日清理所在的自然日。没有值代表这台机器还没跑过这条规则。
        static let lastRolloverDay = "todo.lastRolloverDay"
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) else {
            items = Self.seed()
            save()
            return
        }
        items = decoded
    }

    private func save() {
        guard !isDemo else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 演示模式的示例待办（DEW_DEMO=1），中英文跟随界面语言
    private static func demoItems() -> [TodoItem] {
        let zh = L10n.current == .zh
        func t(_ a: String, _ b: String) -> String { zh ? a : b }
        return [
            TodoItem(title: t("发布 v0.2 到 TestFlight", "Ship v0.2 to TestFlight"), kind: .high, order: 0),
            TodoItem(title: t("过一遍待合并的 PR", "Review open PRs"), kind: .daily, done: true, order: 0,
                     lastCompletedDay: today()),
            TodoItem(title: t("回复社区 issue", "Reply to community issues"), kind: .daily, order: 1),
            TodoItem(title: t("整理竞品清单", "Compile competitor list"), kind: .normal, done: true, order: 0),
            TodoItem(title: t("写 onboarding 文案", "Write onboarding copy"), kind: .normal, order: 1),
            TodoItem(title: t("约三位用户做访谈", "Schedule 3 user interviews"), kind: .normal, order: 2),
            TodoItem(title: t("换掉旧 logo", "Replace the old logo"), kind: .normal, done: true, order: 3),
        ]
    }

    /// 首次启动放几条，免得开箱是一片空白
    private static func seed() -> [TodoItem] {
        [
            TodoItem(title: L(.seedDaily1), kind: .daily, order: 0),
            TodoItem(title: L(.seedDaily2), kind: .daily, order: 1),
        ]
    }
}
