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
            if let module = model.badgeModule {
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

            PrimaryModuleRow(module: app.primary)
                .frame(height: Layout.primaryHeight, alignment: .top)

            VStack(spacing: Layout.rowSpacing) {
                ForEach(app.secondary, id: \.id) { module in
                    CompactModuleRow(module: module)
                        .frame(height: Layout.rowHeight)
                }
            }
            .padding(.top, Layout.rowSpacing)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.panelInset)
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
