import SwiftUI
import Combine

/// 用户可调项。皮肤契约（PRD 9.5）管的是「皮肤能改什么」，
/// 这里管的是「用户能改什么」——目前只有透明度，是叠在皮肤之上的一个乘数。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 玻璃着色层的不透明度乘数。
    /// 1.0 = 皮肤原本的浓度；越小越通透，越能看见桌面。
    @Published var tintOpacity: Double {
        didSet { UserDefaults.standard.set(tintOpacity, forKey: Keys.tintOpacity) }
    }

    /// 界面语言。改动同步到 L10n.current，后台线程拼文案时也能读到。
    @Published var language: Language {
        didSet {
            L10n.current = language
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
        }
    }

    /// 是否允许读取 Claude Code 的钥匙串凭据去拉官方额度。
    /// **默认关闭。** 这一步读的是另一个 app 存的凭据、调的是未公开接口，
    /// 必须由用户在看过说明之后自己打开；ClaudeUsageAPI.current/refresh 只在开着时才会被调用。
    @Published var claudeUsageAPIEnabled: Bool {
        didSet {
            UserDefaults.standard.set(claudeUsageAPIEnabled, forKey: Keys.claudeUsageAPI)
            ClaudeUsageAPI.isEnabled = claudeUsageAPIEnabled
        }
    }

    /// 是否允许跟随「会新建会话」的深链（目前只有 Claude 的 claude://resume）。
    /// **默认关闭。** 跟一次就在 Claude 桌面端多一条无标题会话，
    /// 静悄悄堆垃圾的功能不该默认开着。关着时点击退回 Finder 定位日志。
    @Published var importingDeepLinksEnabled: Bool {
        didSet { UserDefaults.standard.set(importingDeepLinksEnabled, forKey: Keys.importingDeepLinks) }
    }

    private enum Keys {
        static let tintOpacity = "skin.tintOpacity"
        static let language = "ui.language"
        static let claudeUsageAPI = "claude.usageAPI.enabled"
        static let importingDeepLinks = "deepLink.allowImport"
    }

    static let tintRange: ClosedRange<Double> = 0.0...1.0

    // 滑块一个值，连续驱动三层：磨砂、白纱、液态高光。
    //
    // 不再分档切换材质——档位之间会「骤降」。磨砂层保底 30%，
    // 所以永远不会完全透明：往低拧是从毛玻璃滑向液态玻璃，
    // 不是滑向「一块透明亚克力」。白纱同样保底，且必须是白的——
    // 全透之后透出的是桌面本色，深色桌面会让面板发灰发脏。
    // 低透明度时补一圈顶部高光，这是液态玻璃「有厚度」的那个视觉线索。

    /// 磨砂层不透明度，0.45 … 1.00。实测 0.30 在杂乱桌面上已接近全透、文字难读。
    static func glassAlpha(for t: Double) -> Double { 0.45 + 0.55 * t }

    /// 白纱浓度。注意 skin.tint 自带 0.7 底，实际 = 0.7 × 本值。
    static func tintAlpha(for t: Double) -> Double { 0.30 + 0.70 * t }

    /// 液态高光强度，越透越明显，满不透明时为 0
    static func highlight(for t: Double) -> Double { (1 - t) * 0.55 }

    private init() {
        let stored = UserDefaults.standard.object(forKey: Keys.tintOpacity) as? Double
        tintOpacity = stored.map { min(max($0, Self.tintRange.lowerBound), Self.tintRange.upperBound) } ?? 0.9
        let lang = UserDefaults.standard.string(forKey: Keys.language).flatMap(Language.init(rawValue:))
        language = lang ?? .systemDefault
        claudeUsageAPIEnabled = UserDefaults.standard.bool(forKey: Keys.claudeUsageAPI)  // 未设置即 false
        importingDeepLinksEnabled = UserDefaults.standard.bool(forKey: Keys.importingDeepLinks)  // 同上
        // 所有存储属性就位后再同步到全局
        L10n.current = language
        ClaudeUsageAPI.isEnabled = claudeUsageAPIEnabled
    }
}
