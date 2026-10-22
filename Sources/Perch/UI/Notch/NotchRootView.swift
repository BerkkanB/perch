import SwiftUI

private typealias Layout = NotchModel.List

/// The content inside the notch, laid out at its final size and centred under the camera.
/// The black shape itself is drawn by `NotchCanvasView` with Core Animation, which also masks
/// this view, so the content is revealed as the shape grows.
struct NotchRootView: View {
    @Environment(AppModel.self) private var app
    let model: NotchModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.contentPhase {
        case .badge?:
            if let session = model.glanceSession {
                AgentWings(session: session, others: model.otherActiveSessions, model: model)
                    .frame(size: model.bodySize(for: .badge))
                    .id(session.id)
                    .transition(.opacity)
            } else if let module = model.badgeModule {
                BadgeWings(module: module, model: model)
                    .frame(size: model.bodySize(for: .badge))
                    .transition(.opacity)
            }
        case .hud?:
            if let message = app.hud.current {
                HUDWings(message: message, notchWidth: model.geometry.notchWidth)
                    .frame(size: model.bodySize(for: .hud))
                    .id(message.id)
                    .transition(.opacity)
            }
        case .expanded?:
            NotchListContent(model: model)
                .frame(size: model.bodySize(for: .expanded))
                .transition(Motion.reduceMotion ? .opacity : .opacity
                    .combined(with: .scale(scale: 0.97, anchor: .top))
                    .combined(with: .modifier(active: Blurred(radius: 6), identity: Blurred(radius: 0))))
        case .idle?, nil:
            EmptyView()
        }
    }
}

private extension View {
    func frame(size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
    }
}

/// Blur as a transition, for content settling into focus as the notch opens.
private struct Blurred: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// The open notch: readings, the main module written out, then a line per other module.
private struct NotchListContent: View {
    @Environment(AppModel.self) private var app
    let model: NotchModel

    var body: some View {

        VStack(spacing: 0) {
            Color.clear.frame(height: model.geometry.notchHeight)

            StatsLine(onSettings: app.openSettings)
                .frame(height: Layout.statsHeight)
                .padding(.top, Layout.statsTop)
                .padding(.horizontal, Layout.rowInset)
                .padding(.bottom, Layout.statsGap)

            if !app.agents.sessions.isEmpty {
                AgentSessionList()
                SectionDivider()
            }

            ControlsSection()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.panelInset)
        .environment(\.agentListWidth, model.listWidth)
    }
}

/// The thin line between the agent sessions and the switches.
struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, NotchModel.List.rowInset)
            .padding(.vertical, (NotchModel.List.sectionDivider - 1) / 2)
    }
}

/// The notch a little wider while a module is on: its symbol (and a thermometer when the Mac
/// runs hot) left of the camera; on the right, the time left when a timer is set, else a dot. Both sides are
/// the same width. Nothing shows below the notch.
private struct BadgeWings: View {
    let module: any PerchModule
    let model: NotchModel

    var body: some View {
        let wing = model.badgeWing

        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: module.symbol)
                    .foregroundStyle(module.tint)
                if model.isRunningHot {
                    Image(systemName: "thermometer.high")
                        .foregroundStyle(heatColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: wing)

            Spacer(minLength: model.geometry.notchWidth)

            Group {
                if let timer = module.timer, timer.isRunning {
                    CountdownLabel(timer: timer, style: .tight)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(module.tint)
                } else {
                    // Balances the symbol on the left when there is no time to show.
                    Circle()
                        .fill(module.tint)
                        .frame(width: 6, height: 6)
                }
            }
            .transition(.opacity)
            .frame(width: wing)
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: wing)
        .animation(.easeInOut(duration: 0.2), value: model.isRunningHot)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var heatColor: Color {
        model.isCriticallyHot ? Palette.danger : Palette.stayAwake
    }

    private var accessibilityText: String {
        var text = "\(module.title) is on"
        if model.isRunningHot { text += ", Mac is running hot" }
        return text
    }
}

/// What an agent is doing, beside the camera: a pulsing dot in its state color, the project and
/// "+N" when more agents are busy on the left; a symbol and the file or command on the right
/// ("✎ middleware.ts"). Both sides are the same width.
private struct AgentWings: View {
    let session: AgentSession
    let others: Int
    let model: NotchModel

    var body: some View {
        let wing = model.badgeWing
        let glance = session.badgeGlance

        HStack(spacing: 0) {
            HStack(spacing: 7) {
                PulsingDot(tint: session.state.color, size: 6)
                Text(model.displayName(of: session))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if others > 0 {
                    Text("+\(others)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize()
                }
            }
            .padding(.leading, 14)
            .frame(width: wing, alignment: .leading)

            Spacer(minLength: model.geometry.notchWidth)

            HStack(spacing: 5) {
                Image(systemName: glance.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(glance.text)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(session.state.color)
            .padding(.trailing, 14)
            .frame(width: wing, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.2), value: glance)
        .animation(.easeInOut(duration: 0.2), value: session.state)
        .accessibilityElement()
        .accessibilityLabel("\(session.project): \(session.statusText)")
    }
}

/// "☀ Stay Awake ··· on 1h", split around the camera.
private struct HUDWings: View {
    let message: HUDMessage
    let notchWidth: CGFloat

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: message.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(message.tint)
                    .symbolEffect(.bounce, value: appeared)
                Text(message.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .frame(width: NotchModel.hudWing, alignment: .leading)

            Spacer(minLength: notchWidth)

            Text(message.value.lowercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(message.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.trailing, 14)
                .frame(width: NotchModel.hudWing, alignment: .trailing)
        }
        .onAppear { appeared = true }
    }
}
