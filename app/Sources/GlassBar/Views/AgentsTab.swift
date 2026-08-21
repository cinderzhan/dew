import SwiftUI

struct AgentsTab: View {
    /// 「已完成」在界面上最多露几条
    static let doneVisibleLimit = 4

    @EnvironmentObject var agents: AgentStore
    let skin: Skin

    var body: some View {
        let needs   = agents.sessions(in: .needsYou)
        let running = agents.sessions(in: .running)
        let done    = agents.sessions(in: .done)
        let empty   = needs.isEmpty && running.isEmpty && done.isEmpty && agents.tasks.isEmpty

        // 必须有显式容器。body 直接返回一组并列视图（TupleView）时，
        // 排布要靠父级展平；套在 switch + ScrollView 里时这个展平不可靠，
        // 表现为某一格没被排进流里、叠在后面的内容上。
        VStack(alignment: .leading, spacing: 0) {
            if empty {
                EmptyHint(text: L(.emptyAgents), skin: skin)
            } else {
                if !needs.isEmpty {
                    GroupHeader(title: L(.stateNeedsYou), skin: skin, accent: skin.signal)
                    ForEach(needs) { SessionRow(session: $0, skin: skin) }
                }
                if !running.isEmpty {
                    GroupHeader(title: L(.stateRunning), skin: skin)
                    ForEach(running) { SessionRow(session: $0, skin: skin) }
                }
                if !done.isEmpty {
                    GroupHeader(title: L(.stateDone), skin: skin)
                    // 只露前几条。「已完成」是一次性信息，堆多了会把定时任务挤出视口，
                    // 而定时任务是要常驻的（PRD 6.1）。
                    ForEach(done.prefix(Self.doneVisibleLimit)) { SessionRow(session: $0, skin: skin) }
                    if done.count > Self.doneVisibleLimit {
                        Text(L(.moreDone, done.count - Self.doneVisibleLimit))
                            .font(Metrics.metaFont)
                            .foregroundStyle(skin.faint)
                            .padding(.horizontal, Metrics.hPad)
                            .padding(.vertical, 4)
                    }
                }
                if !agents.tasks.isEmpty {
                    GroupHeader(title: L(.groupScheduled), skin: skin)
                    ForEach(agents.tasks) { TaskRow(task: $0, skin: skin) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionRow: View {
    @EnvironmentObject var agents: AgentStore
    let session: AgentSession
    let skin: Skin
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            marker
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.summary)
                    .font(Metrics.bodyFont)
                    .foregroundStyle(session.state == .needsYou ? skin.signal
                                     : (session.state == .done ? skin.dim : skin.text))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    Text(session.kind.displayName)
                    Text("·")
                    Text(session.projectName)
                }
                .font(Metrics.metaFont)
                .foregroundStyle(skin.faint)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(timeText)
                .font(Metrics.metaFont)
                .foregroundStyle(skin.faint)
                .monospacedDigit()
                .padding(.top, 1)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.rowVPad)
        .background(hovering ? skin.selection : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { agents.reveal(session) }
        .help(session.cwd ?? session.sourcePath)
    }

    @ViewBuilder private var marker: some View {
        switch session.state {
        case .running:
            StateDot(color: skin.running, radius: skin.dotCornerRadius, pulsing: true)
        case .needsYou:
            StateDot(color: skin.signal, radius: skin.dotCornerRadius)
        case .done:
            StateDot(color: skin.done, radius: skin.dotCornerRadius)
        default:
            StateDot(color: skin.line, radius: skin.dotCornerRadius)
        }
    }

    private var timeText: String {
        session.state == .done
        ? RelTime.clockText(session.changedAt)
        : RelTime.sinceText(session.changedAt)
    }
}

struct TaskRow: View {
    @EnvironmentObject var agents: AgentStore
    let task: ScheduledTask
    let skin: Skin
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // 定时任务用空心菱形，和会话的实心点区分开
            Rectangle()
                .stroke(skin.faint, lineWidth: 1)
                .frame(width: 5, height: 5)
                .rotationEffect(.degrees(45))
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(Metrics.bodyFont)
                    .foregroundStyle(skin.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(task.kind.displayName)
                    Text("·")
                    Text(task.scheduleText)
                }
                .font(Metrics.metaFont)
                .foregroundStyle(skin.faint)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(RelTime.untilText(task.nextRun))
                .font(Metrics.metaFont)
                .foregroundStyle(skin.faint)
                .monospacedDigit()
                .padding(.top, 1)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.rowVPad)
        .background(hovering ? skin.selection : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { agents.reveal(task) }
        .help(task.sourcePath)
    }
}
