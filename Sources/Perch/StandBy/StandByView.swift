import SwiftUI

/// Where StandBy's content is in its entrance or exit. `StandByController` moves it along; every
/// window of one StandBy shares it.
@MainActor
@Observable
final class StandByPresentation {
    enum Phase {
        /// Drawn but not in yet: a little small, blurred and clear.
        case entering
        case shown
        /// On its way out: zooming toward you and fading.
        case leaving
    }

    var phase: Phase = .entering
    /// How long the content waits for the black to fade in before it comes in.
    var delay: Double = 0.15
}

/// StandBy's screen: a large clock and the date with a line of readings on the left, the coding
/// agents on the right. Other screens just go black.
struct StandByView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: StandByPresentation
    let showsContent: Bool
    let requiresAuth: Bool
    let onDismiss: () -> Void

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
                        .modifier(Entrance(presentation: presentation, step: 1, rise: 16))
                }
                .padding(.horizontal, 88)
                // On the way out everything zooms together, from the middle of the screen.
                .scaleEffect(presentation.phase == .leaving && !reduceMotion ? 1.06 : 1)
                .animation(reduceMotion ? Motion.reduced : Motion.standbyOut, value: presentation.phase == .leaving)

                VStack {
                    Spacer()
                    Text(requiresAuth ? "Click or press a key, then use Touch ID to close" : "Click or press a key to close")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.tertiary)
                        .opacity(showsHint && presentation.phase == .shown ? 1 : 0)
                        .padding(.bottom, 40)
                }
                .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.agentsInteractive, !requiresAuth)
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
            .modifier(Entrance(presentation: presentation, step: 0, scale: 0.94))
            StatsLine(fontSize: 16)
                .padding(.top, 28)
                .fixedSize()
                .modifier(Entrance(presentation: presentation, step: 2, rise: 10))
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

/// Brings one part of StandBy in `step` beats after the black, blurred and a little small or low,
/// and fades it out with the rest. Only cross-fades with Reduce Motion on.
///
/// Parts holding a scroll view rise rather than scale: scaling resizes the scroll view, which
/// leaves it scrolled a few points down.
private struct Entrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: StandByPresentation
    let step: Int
    var scale: CGFloat = 1
    var rise: CGFloat = 0

    func body(content: Content) -> some View {
        let isShown = presentation.phase == .shown
        let isMoving = !isShown && !reduceMotion
        let isEntering = isMoving && presentation.phase == .entering
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isEntering ? scale : 1)
            .offset(y: isEntering ? rise : 0)
            .blur(radius: isMoving ? 14 : 0)
            .animation(animation(isShown: isShown), value: presentation.phase)
    }

    private func animation(isShown: Bool) -> Animation {
        if reduceMotion { return Motion.reduced }
        guard isShown else { return Motion.standbyOut }
        return Motion.standbyIn.delay(presentation.delay + Double(step) * Motion.standbyStagger)
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
