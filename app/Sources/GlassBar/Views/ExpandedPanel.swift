import SwiftUI

struct ExpandedPanel: View {
    @EnvironmentObject var agents: AgentStore
    @EnvironmentObject var todos: TodoStore
    let skin: Skin
    @Binding var tab: PanelTab
    @ObservedObject private var chrome = PanelChrome.shared

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if chrome.showSettings { SettingsPane(skin: skin) }
            Divider().overlay(skin.line).opacity(0.001) // 占位，真正的分隔在分组内
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .agents: AgentsTab(skin: skin)
                    case .todo:   TodoTab(skin: skin)
                    case .usage:  UsageTab(skin: skin)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(ScrollTrailFix().frame(width: 0, height: 0))
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(width: Metrics.expandedSize.width, height: Metrics.expandedSize.height)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { t in
                let selected = tab == t
                Button {
                    tab = t
                    if t == .agents { agents.beginViewingAgents() }
                    if t == .usage {
                        ClaudeUsageAPI.refreshIfNeeded(force: true)
                        agents.refresh(forceQuota: true)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(t.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        if let c = dotColor(for: t) {
                            // 只点一个小点、只取一个颜色。带数字的角标太重，像在催人。
                            Circle().fill(c).frame(width: 5, height: 5)
                                .offset(y: -4)
                        }
                    }
                    .foregroundStyle(selected ? skin.text : skin.faint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? skin.selection : .clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Button { chrome.showSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chrome.showSettings ? skin.text : skin.faint)
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help(L(.settings))

            Button { PanelChrome.shared.collapse() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.faint)
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help(L(.collapse))
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
        // 标签栏兼作拖动区：按钮在前，落在空白处的按下才会交给它
        .background(WindowDragArea())
    }

    /// Agents 的点按优先级只取一个颜色：等你介入(红) > 已完成(绿) > 进行中(橙)。
    /// 待办是你自己写的，不用被提醒；用量不算事。
    private func dotColor(for t: PanelTab) -> Color? {
        guard t == .agents else { return nil }
        if !agents.sessions(in: .needsYou).isEmpty { return skin.signal }
        if !agents.sessions(in: .done).isEmpty     { return skin.done }
        if !agents.sessions(in: .running).isEmpty  { return skin.running }
        return nil
    }

    /// 底栏：两个 tab 各自的计数，兼作拖动区。
    private var footer: some View {
        HStack(spacing: 8) {
            Text(L(.sessionsCount, agents.visibleSessions.count))
            Spacer()
            Text(L(.todosCount, todos.openCount))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(skin.faint)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 8)
        .background(WindowDragArea())
        .overlay(alignment: .top) { Rectangle().fill(skin.line).frame(height: 0.5) }
    }
}

// MARK: - 分组标题
//
// C 玻璃方向的语气特征：用普通句式，不用全大写字距标签。
// 这是它区别于其它方向的地方，别改成 uppercase。

struct GroupHeader: View {
    let title: String
    let skin: Skin
    var accent: Color?

    var body: some View {
        Text(title)
            .font(Metrics.groupFont)
            .foregroundStyle(accent ?? skin.faint)
            .padding(.horizontal, Metrics.hPad)
            .padding(.top, 9)
            .padding(.bottom, 5)
    }
}

struct EmptyHint: View {
    let text: String
    let skin: Skin
    var body: some View {
        Text(text)
            .font(Metrics.metaFont)
            .foregroundStyle(skin.faint)
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 10)
    }
}
