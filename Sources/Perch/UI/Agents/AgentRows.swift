import SwiftUI

private typealias Layout = NotchModel.List

extension AgentSession.State {
    /// Blue while working, orange while it needs you, green when done.
    var color: Color {
        switch self {
        case .working: Color.blue
        case .waiting: Palette.stayAwake
        case .done: Palette.good
        case .idle: Color.white.opacity(0.3)
        }
    }
}

/// The coding agent sessions: the most important one written out, the rest one line each.
struct AgentSessionList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sessions = app.agents.sessions

        if let first = sessions.first {
            VStack(spacing: Layout.rowSpacing) {
                AgentSessionCard(session: first)
                    .frame(height: Layout.sessionCardHeight(hasApproval: first.approval != nil), alignment: .top)

                ForEach(sessions.dropFirst().prefix(Layout.maxCompactSessions)) { session in
                    AgentSessionRow(session: session)
                        .frame(height: Layout.rowHeight)
                }

                let hidden = sessions.count - 1 - Layout.maxCompactSessions
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(Ink.body)
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Layout.rowInset + 36)
                        .frame(height: Layout.moreRowHeight)
                }
            }
        }
    }
}

/// A session written out: project, your last prompt, what it's doing in its state color, and
/// Allow / Deny when it needs approval. Clicking it brings its terminal forward.
struct AgentSessionCard: View {
    @Environment(AppModel.self) private var app
    let session: AgentSession

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 14) {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(session.state.color)
                    .frame(width: 22, height: 22)
                Text(session.project)
                    .font(Ink.title)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SessionMeta(session: session)
            }

            Group {
                Text(session.lastPrompt.map { "You: \($0)" } ?? "No prompt yet")
                    .foregroundStyle(Ink.secondary)
                Text(session.statusText)
                    .foregroundStyle(session.state == .idle ? Ink.secondary : session.state.color)
            }
            .font(Ink.body)
            .lineLimit(1)
            .padding(.leading, 36)

            if let approval = session.approval {
                ApprovalBox(session: session, approval: approval)
                    .padding(.leading, 36)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isHovered ? Ink.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.agents.jump(to: session.id) }
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: session.state)
        .help("Show in \(session.terminal?.appName ?? "its terminal")")
    }
}

/// One line per other session: a dot in its state color, the project, agent and terminal, age.
struct AgentSessionRow: View {
    @Environment(AppModel.self) private var app
    let session: AgentSession

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(session.state.color)
                .frame(width: 8, height: 8)
                .frame(width: 22)
            Text(session.project)
                .font(Ink.compactTitle)
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 8)
            SessionMeta(session: session)
        }
        .padding(.horizontal, Layout.rowInset)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovered ? Ink.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.agents.jump(to: session.id) }
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(session.statusText)
    }
}

/// "[Claude] [Ghostty] 27m"
private struct SessionMeta: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            TagChip(text: session.agent.displayName)
            if let terminal = session.terminal?.appName {
                TagChip(text: terminal)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let age = context.date.timeIntervalSince(session.startedAt)
                Text(age < 60 ? "now" : DurationFormat.tight(age))
                    .font(Ink.body)
                    .foregroundStyle(Ink.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
    }
}

/// What the agent wants to run, with Allow and Deny. "Terminal" leaves the choice to the agent's
/// own prompt and brings its terminal forward.
private struct ApprovalBox: View {
    @Environment(AppModel.self) private var app
    let session: AgentSession
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(approval.tool)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.stayAwake)
                Text(approval.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: Layout.approvalDetailHeight, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))

            HStack(spacing: 8) {
                Button("Answer in Terminal") { app.agents.answerInTerminal(session.id) }
                    .buttonStyle(.plain)
                    .font(Ink.body)
                    .foregroundStyle(Ink.secondary)
                Spacer()
                ApprovalButton(title: "Deny", isProminent: false) { app.agents.decide(session.id, allow: false) }
                ApprovalButton(title: "Allow", isProminent: true) { app.agents.decide(session.id, allow: true) }
            }
            .frame(height: Layout.approvalButtonsHeight)
        }
    }
}

private struct ApprovalButton: View {
    let title: String
    let isProminent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : Ink.primary)
                .padding(.horizontal, 18)
                .frame(height: Layout.approvalButtonsHeight)
                .background(
                    Capsule().fill(isProminent ? Color.white.opacity(isHovered ? 0.85 : 1) : Color.white.opacity(isHovered ? 0.18 : 0.12))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
    }
}

/// "✦ 5h 11% 4h1m | 7d 2% 6h1m": Claude's 5-hour and weekly limits, used share and time to reset.
struct UsageReadout: View {
    let usage: AgentUsage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                if let window = usage.fiveHour, window.resetsAt > context.date {
                    reading("5h", window, now: context.date)
                }
                if let fiveHour = usage.fiveHour, fiveHour.resetsAt > context.date,
                   let sevenDay = usage.sevenDay, sevenDay.resetsAt > context.date {
                    Text("|").foregroundStyle(Ink.separator)
                }
                if let window = usage.sevenDay, window.resetsAt > context.date {
                    reading("7d", window, now: context.date)
                }
            }
        }
    }

    private func reading(_ label: String, _ window: AgentUsage.Window, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.bold).foregroundStyle(Ink.primary)
            Text("\(Int(window.usedPercent.rounded()))%").fontWeight(.bold).foregroundStyle(color(for: window.usedPercent))
            Text(DurationFormat.tight(window.resetsAt.timeIntervalSince(now))).foregroundStyle(Ink.secondary)
        }
    }

    private func color(for percent: Double) -> Color {
        if percent < 50 { return Palette.good }
        return percent < 80 ? Palette.warning : Palette.danger
    }
}

extension AgentUsage {
    /// Whether any window is still current.
    func isCurrent(at date: Date = .now) -> Bool {
        [fiveHour, sevenDay].contains { ($0?.resetsAt ?? .distantPast) > date }
    }
}
