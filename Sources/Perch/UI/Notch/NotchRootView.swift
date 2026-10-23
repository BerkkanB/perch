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
            if let message = app.hud.current, message.isDone {
                DoneWings(message: message, notchWidth: model.geometry.notchWidth, wing: model.hudWing)
                    .frame(size: model.bodySize(for: .hud))
                    .id(message.id)
                    .transition(Motion.reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity,
                        removal: .opacity
                            .combined(with: .scale(scale: 0.82, anchor: .top))
                            .combined(with: .modifier(active: Blurred(radius: 5), identity: Blurred(radius: 0)))
                    ))
            } else if let message = app.hud.current {
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
                AgentStatusMark(session: session, size: .notch)
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
                if let symbol = glance.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
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
            .frame(width: NotchModel.baseHUDWing, alignment: .leading)

            Spacer(minLength: notchWidth)

            Text(message.value.lowercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(message.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.trailing, 14)
                .frame(width: NotchModel.baseHUDWing, alignment: .trailing)
        }
        .onAppear { appeared = true }
    }
}

/// An agent finished: "✓ auth-service" left of the camera, "Done 4m" right of it. The tick pops
/// in and draws itself while the name and "Done" slide out from the camera, sharpening as they
/// arrive; leaving, everything draws back into the camera.
private struct DoneWings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: HUDMessage
    let notchWidth: CGFloat
    let wing: CGFloat

    @State private var appeared = false

    private typealias Done = NotchModel.Done

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Done.tickGap) {
                DoneTick(tint: message.tint, size: Done.tickSize)
                Text(message.title)
                    .font(.system(size: Done.titleSize, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .modifier(emerging(from: -1, delay: 0.06))
            }
            .padding(.leading, Done.edgePadding)
            .frame(width: wing, alignment: .leading)

            Spacer(minLength: notchWidth)

            HStack(alignment: .firstTextBaseline, spacing: Done.valueGap) {
                Text(message.value)
                    .font(.system(size: Done.valueSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(message.tint)
                if let detail = message.detail {
                    Text(detail)
                        .font(.system(size: Done.valueSize, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                }
            }
            .lineLimit(1)
            // As the check finishes drawing.
            .modifier(emerging(from: 1, delay: 0.24))
            .padding(.trailing, Done.edgePadding)
            .frame(width: wing, alignment: .trailing)
        }
        .onAppear { appeared = true }
    }

    /// Slides in from the camera's side (`side` -1 for the left wing, 1 for the right), out of a
    /// light blur.
    private func emerging(from side: CGFloat, delay: Double) -> Emerging {
        Emerging(isIn: appeared || reduceMotion, offset: -side * 12, animation: .smooth(duration: 0.5).delay(delay))
    }
}

private struct Emerging: ViewModifier {
    let isIn: Bool
    let offset: CGFloat
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .opacity(isIn ? 1 : 0)
            .offset(x: isIn ? 0 : offset)
            .blur(radius: isIn ? 0 : 4)
            .animation(animation, value: isIn)
    }
}
