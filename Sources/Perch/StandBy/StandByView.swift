import SwiftUI

/// StandBy's screen: a large clock and the date with a line of readings on the left, the coding
/// agents on the right. Other screens just go black.
struct StandByView: View {
    @Environment(AppModel.self) private var app
    let showsContent: Bool
    let requiresAuth: Bool
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var showsHint = false
    @State private var hintTask: Task<Void, Never>?

    private static let agentsWidth: CGFloat = 520

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            if showsContent {
                HStack(alignment: .center, spacing: 72) {
                    clock
                        .frame(maxWidth: .infinity, alignment: .leading)
                    agents
                        .frame(width: Self.agentsWidth)
                        .environment(\.agentListWidth, Self.agentsWidth)
                }
                .padding(.horizontal, 88)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)

                VStack {
                    Spacer()
                    Text(requiresAuth ? "Click or press a key, then use Touch ID to close" : "Click or press a key to close")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.tertiary)
                        .opacity(showsHint ? 1 : 0)
                        .padding(.bottom, 40)
                }
                .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.agentsInteractive, !requiresAuth)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9).delay(0.15)) { appeared = true }
        }
        .onContinuousHover { _ in revealHint() }
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 168, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Ink.primary)
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.6), value: context.date)
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 26))
                        .foregroundStyle(Ink.secondary)
                }
            }
            StatsLine(fontSize: 16)
                .padding(.top, 28)
                .fixedSize()
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENTS")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Ink.tertiary)
                .padding(.leading, NotchModel.List.rowInset)
            if app.agents.sessions.isEmpty {
                Text("No agents running")
                    .font(Ink.title)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.leading, NotchModel.List.rowInset)
            } else {
                AgentSessionList()
            }
        }
    }

    /// Shows the "how to close" line for a few seconds after the pointer moves.
    private func revealHint() {
        withAnimation(.easeOut(duration: 0.3)) { showsHint = true }
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.6)) { showsHint = false }
        }
    }
}

private struct AgentsInteractiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether agent rows take clicks (Allow / Deny, jump to terminal). StandBy turns this off
    /// while closing it needs Touch ID, so nobody passing by can approve a command.
    var agentsInteractive: Bool {
        get { self[AgentsInteractiveKey.self] }
        set { self[AgentsInteractiveKey.self] = newValue }
    }
}
