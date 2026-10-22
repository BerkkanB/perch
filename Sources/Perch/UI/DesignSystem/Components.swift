import AppKit
import SwiftUI

// MARK: Duration choices

/// The options offered for "turn off after".
enum DurationChoice: Hashable, Identifiable {
    case never
    case after(TimeInterval)

    static let all: [DurationChoice] = [.never] + AutoOffTimer.presets.map { .after($0) }

    var id: String { label }

    var label: String {
        switch self {
        case .never: "Never"
        case .after(let seconds): DurationFormat.preset(seconds)
        }
    }

    var seconds: TimeInterval? {
        if case .after(let seconds) = self { return seconds }
        return nil
    }

    /// The current choice for a module, or `nil` while it's off.
    @MainActor
    static func current(for module: any PerchModule) -> DurationChoice? {
        guard module.isOn else { return nil }
        return module.timer?.duration.map { .after($0) } ?? .never
    }
}

// MARK: Time

/// "On until 14:32", or "On" when there's no timer.
struct UntilLabel: View {
    let module: any PerchModule

    var body: some View {
        if let end = module.timer?.endsAt {
            Text("On until \(end.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("On")
        }
    }
}

/// Live "42m left", "1h 5m" or "1h5m".
struct CountdownLabel: View {
    enum Style { case long, compact, tight }

    let timer: AutoOffTimer
    var style: Style = .long

    var body: some View {
        if let end = timer.endsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, end.timeIntervalSince(context.date))
                Text(Self.format(remaining, style))
                    .monospacedDigit()
            }
        }
    }
}

extension CountdownLabel {
    static func format(_ seconds: TimeInterval, _ style: Style) -> String {
        switch style {
        case .long: DurationFormat.remaining(seconds)
        case .compact: DurationFormat.compact(seconds)
        case .tight: DurationFormat.tight(seconds)
        }
    }
}

struct NoticeRow: View {
    let notice: ModuleNotice

    var body: some View {
        Label {
            Text(notice.message) + Text("  \(notice.date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var symbol: String {
        switch notice.kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .info: .secondary
        case .warning: .orange
        case .error: Palette.danger
        }
    }
}

/// Soft dot that breathes, for "something is happening".
///
/// The pulse is a Core Animation layer animation, which the window server runs by itself.
/// A SwiftUI animation would wake the app every frame, and this dot can stay up for hours.
struct PulsingDot: NSViewRepresentable {
    var tint: Color
    var size: CGFloat = 7

    func makeNSView(context: Context) -> PulseDotView {
        PulseDotView()
    }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.configure(color: NSColor(tint), diameter: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseDotView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class PulseDotView: NSView {
    private let dot = CALayer()
    private let halo = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        halo.opacity = 0
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(color: NSColor, diameter: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for circle in [dot, halo] {
            circle.backgroundColor = color.cgColor
            circle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            circle.cornerRadius = diameter / 2
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.position = center
        halo.position = center
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        halo.removeAllAnimations()
        guard window != nil else { return }

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        for animation in [grow, fade] {
            animation.duration = 1.4
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 2.2
        pulse.repeatCount = .infinity
        halo.add(pulse, forKey: "pulse")
    }
}
