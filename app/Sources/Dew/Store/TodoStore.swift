import Foundation
import Combine

/// 个人 to-do。纯本地单文件，无账号无云（PRD 7.3）。
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = []

    private let fileURL: URL
    private var dayCheckTimer: Timer?

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Dew")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "todos.json")

        load()
        resetDailyIfNeeded()

        // 跨自然日时把每日重复项重置为未完成
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resetDailyIfNeeded() }
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

    func move(_ item: TodoItem, to kind: TodoKind) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].kind = kind
        items[i].order = (items.filter { $0.kind == kind }.map(\.order).max() ?? -1) + 1
        save()
    }

    // MARK: - 每日重置

    private func resetDailyIfNeeded() {
        let today = Self.today()
        var changed = false
        for i in items.indices where items[i].kind == .daily {
            if items[i].done, items[i].lastCompletedDay != today {
                items[i].done = false
                changed = true
            }
        }
        if changed { save() }
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
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 首次启动放几条，免得开箱是一片空白
    private static func seed() -> [TodoItem] {
        [
            TodoItem(title: L(.seedDaily1), kind: .daily, order: 0),
            TodoItem(title: L(.seedDaily2), kind: .daily, order: 1),
        ]
    }
}
