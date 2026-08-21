import Foundation

/// 改名 GlassBar → Dew 的一次性迁移：把旧的偏好和待办文件搬过来，不丢用户数据。
/// 只在新位置还是空的时候执行，跑过一次后再也不碰旧数据。
enum Migration {
    static func runIfNeeded() {
        migrateDefaults()
        migrateTodos()
    }

    private static func migrateDefaults() {
        let new = UserDefaults.standard
        guard new.object(forKey: "migrated.fromGlassBar") == nil else { return }
        if let old = UserDefaults(suiteName: "com.cinder.glassbar") {
            for key in ["skin.tintOpacity", "ui.language", "claude.usageAPI.enabled", "panel.origin"] {
                if new.object(forKey: key) == nil, let v = old.object(forKey: key) {
                    new.set(v, forKey: key)
                }
            }
        }
        new.set(true, forKey: "migrated.fromGlassBar")
    }

    private static func migrateTodos() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldFile = base.appending(path: "GlassBar/todos.json")
        let newDir = base.appending(path: "Dew")
        let newFile = newDir.appending(path: "todos.json")
        guard fm.fileExists(atPath: oldFile.path), !fm.fileExists(atPath: newFile.path) else { return }
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: oldFile, to: newFile)
    }
}
