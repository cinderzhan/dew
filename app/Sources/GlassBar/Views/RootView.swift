import SwiftUI

enum PanelTab: String, CaseIterable {
    case agents, todo, usage
    var label: String {
        switch self {
        case .agents: return L(.tabAgents)
        case .todo:   return L(.tabTodo)
        case .usage:  return L(.tabUsage)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var agents: AgentStore
    @EnvironmentObject var todos: TodoStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @ObservedObject var chrome: PanelChrome
    @State private var tab: PanelTab = .agents

    private var skin: Skin { .plain(scheme) }

    var body: some View {
        Group {
            if chrome.isExpanded {
                ExpandedPanel(skin: skin, tab: $tab)
                    .onChange(of: chrome.pendingTab) { _, new in
                        if let new { tab = new; chrome.pendingTab = nil }
                    }
                    // onChange 只认视图出现之后的变化；请求若发生在出现之前会丢，
                    // 所以出现时再兜底消费一次。
                    .onAppear {
                        if let p = chrome.pendingTab { tab = p; chrome.pendingTab = nil }
                    }
            } else {
                CollapsedBar(skin: skin)
            }
        }
        // 换语言时整棵树重建一次。文案是函数调用不是绑定，不重建不会刷新。
        .id(settings.language)
        // 着色必须叠在磨砂**上面**。写成两层 .background 会把着色压到
        // NSVisualEffectView 后面，被材质整个盖住，调了等于没调。
        .background {
            ZStack {
                GlassBackground(alpha: AppSettings.glassAlpha(for: settings.tintOpacity))
                skin.tint.opacity(AppSettings.tintAlpha(for: settings.tintOpacity))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(skin.line, lineWidth: 0.5)
        )
        // 液态玻璃的「厚度」：顶缘一道细高光，越透越明显。
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(AppSettings.highlight(for: settings.tintOpacity)),
                                 Color.white.opacity(AppSettings.highlight(for: settings.tintOpacity) * 0.25),
                                 .clear],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                .blendMode(.plusLighter)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        // 只在折叠态挂点击手势。挂在整个容器上时，展开态里的复选框、
        // 滑块会被它抢走事件——即使闭包本身什么都不做。
        .contentShape(Rectangle())
        .modifier(TapToExpand(enabled: !chrome.isExpanded) {
            chrome.expand()
        })
        // 所有展开路径（点击、菜单栏、快捷键、调试开关）都经过这里，
        // 「已完成」的看过/隐藏节奏只在这一处维护。
        .onChange(of: chrome.isExpanded) { _, expanded in
            if expanded {
                if tab == .agents { agents.beginViewingAgents() }
            } else {
                agents.endViewing()
            }
        }
    }
}

// MARK: - 折叠态
//
// 铁律：只显示一个信号。这里放什么，就是整个产品的气质。
// 想加第二条信息之前，先回去读 PRD 5.1。

struct CollapsedBar: View {
    @EnvironmentObject var agents: AgentStore
    @EnvironmentObject var todos: TodoStore
    let skin: Skin

    var body: some View {
        let sig = agents.collapsedSignal(hasHighPriorityTodo: todos.hasUnfinishedHighPriority)

        HStack(spacing: 9) {
            StateDot(color: sig.state.map(skin.color(for:)) ?? skin.faint,
                     radius: skin.dotCornerRadius,
                     pulsing: sig.state == .running)

            Text(sig.text)
                .font(Metrics.sigFont)
                .foregroundStyle(skin.text)
                .lineLimit(1)

            Spacer(minLength: 4)

            if sig.hasHighPriorityTodo {
                // 高优待办的极轻标记：一根短竖线，不抢主信号
                RoundedRectangle(cornerRadius: 1)
                    .fill(skin.signal.opacity(0.55))
                    .frame(width: 2, height: 10)
            }
            if let d = sig.detail {
                Text(d)
                    .font(Metrics.metaFont)
                    .foregroundStyle(skin.faint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(width: Metrics.collapsedSize.width, height: Metrics.collapsedSize.height)
    }
}

struct StateDot: View {
    let color: Color
    var radius: CGFloat = 0
    var pulsing: Bool = false
    @State private var on = true

    var body: some View {
        Group {
            if radius > 0 {
                RoundedRectangle(cornerRadius: radius).fill(color)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 6, height: 6)
        .opacity(pulsing ? (on ? 1 : 0.28) : 1)
        .animation(pulsing ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                   value: on)
        .onAppear { if pulsing { on = false } }
    }
}


/// 折叠态才响应整体点击；展开态完全不挂手势，把事件让给里面的控件。
struct TapToExpand: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}
