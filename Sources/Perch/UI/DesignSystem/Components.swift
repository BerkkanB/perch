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

/// The tick for a finished agent: a green disc pops in with a flare of light, the check draws
/// itself across it, and a thin ring rings out once; a faint glow stays. Core Animation plays it,
/// like `PulsingDot`; with Reduce Motion on the tick is simply there.
struct DoneTick: NSViewRepresentable {
    var tint: Color = Palette.good
    var size: CGFloat = 18

    func makeNSView(context: Context) -> DoneTickView {
        DoneTickView()
    }

    func updateNSView(_ view: DoneTickView, context: Context) {
        view.configure(color: NSColor(tint), diameter: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DoneTickView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class DoneTickView: NSView {
    private let ring = CAShapeLayer()
    private let disc = CAShapeLayer()
    private let check = CAShapeLayer()
    private var hasPlayed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.fillColor = nil
        ring.lineWidth = 1.2
        ring.opacity = 0
        disc.shadowOffset = .zero
        disc.shadowRadius = 5
        disc.shadowOpacity = 0.4
        check.fillColor = nil
        // Black, so the check looks cut out of the disc, like checkmark.circle.fill.
        check.strokeColor = NSColor.black.cgColor
        check.lineCap = .round
        check.lineJoin = .round
        for part in [ring, disc, check] { layer?.addSublayer(part) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(color: NSColor, diameter: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeColor = color.cgColor
        disc.fillColor = color.cgColor
        disc.shadowColor = color.cgColor
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let circle = CGPath(ellipseIn: bounds, transform: nil)
        ring.path = circle
        disc.path = circle
        disc.shadowPath = circle
        check.lineWidth = diameter * 0.12

        // Drawn in the layer's own coordinates, where y goes up: down to the corner, then up.
        let inset = bounds.insetBy(dx: diameter * 0.28, dy: diameter * 0.3)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset.minX, y: inset.minY + inset.height * 0.48))
        path.addLine(to: CGPoint(x: inset.minX + inset.width * 0.38, y: inset.minY + inset.height * 0.02))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        check.path = path
        for part in [ring, disc, check] { part.bounds = bounds }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [ring, disc, check] { part.position = center }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasPlayed else { return }
        hasPlayed = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime() + 0.05

        // 1. The disc pops in with a little overshoot.
        let pop = CASpringAnimation(perceptualDuration: 0.42, bounce: 0.35)
        pop.keyPath = "transform.scale"
        pop.fromValue = 0.2
        pop.toValue = 1
        pop.duration = pop.settlingDuration
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.duration = 0.12
        // Light flares as it lands, then settles to a faint glow.
        let flare = CAKeyframeAnimation(keyPath: "shadowOpacity")
        flare.values = [0, 0.95, 0.4]
        flare.keyTimes = [0, 0.3, 1]
        flare.duration = 0.9
        flare.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for (key, animation) in [("pop", pop), ("show", show), ("flare", flare)] as [(String, CAAnimation)] {
            animation.beginTime = now
            animation.fillMode = .backwards
            disc.add(animation, forKey: key)
        }

        // 2. The check draws itself, from the short stroke to the long one.
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = now + 0.14
        draw.duration = 0.32
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        draw.fillMode = .backwards
        check.add(draw, forKey: "draw")

        // 3. A ring goes out once and fades. Hidden before and after, so no fill mode.
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        let ringOut = CAAnimationGroup()
        ringOut.animations = [grow, fade]
        ringOut.beginTime = now + 0.18
        ringOut.duration = 0.65
        ringOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(ringOut, forKey: "ring")
    }
}

/// "Working": a 3×3 grid of dots with a band of three lit dots stepping through it, after
/// assistant-ui's GenerationLoader (a 0.3 s fade every 0.36 s). The unlit dots sit at 25%
/// rather than its 15%, since a colored dot on black fades out sooner than a white one.
///
/// Each dot's fades are one repeating Core Animation keyframe track, so the window server plays
/// it and the app sleeps however long an agent works. Every grid keeps time with the same clock,
/// so several on screen step together. With Reduce Motion on, the band stays still.
struct DotMatrix: NSViewRepresentable {
    var tint: Color
    /// One dot's diameter.
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5

    func makeNSView(context: Context) -> DotMatrixView {
        DotMatrixView()
    }

    func updateNSView(_ view: DotMatrixView, context: Context) {
        view.configure(color: NSColor(tint), dot: dot, gap: gap)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DotMatrixView, context: Context) -> CGSize? {
        let side = 3 * dot + 2 * gap
        return CGSize(width: side, height: side)
    }
}

final class DotMatrixView: NSView {
    private let dots = (0..<9).map { _ in CALayer() }
    private var dotSize: CGFloat = 3
    private var gap: CGFloat = 1.5

    static let step: CFTimeInterval = 0.36
    static let fade: CFTimeInterval = 0.3
    static let lit: Float = 0.9
    static let dim: Float = 0.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for dot in dots { layer?.addSublayer(dot) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Whether dot `index` (row by row from the top left) is lit at `step`: the band moves two
    /// dots each step, wrapping through all nine.
    static func isLit(_ index: Int, step: Int) -> Bool {
        (index * 2 + step) % 9 < 3
    }

    func configure(color: NSColor, dot: CGFloat, gap: CGFloat) {
        dotSize = dot
        self.gap = gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in dots.enumerated() {
            layer.backgroundColor = color.cgColor
            layer.cornerRadius = dot / 2
            layer.bounds = CGRect(x: 0, y: 0, width: dot, height: dot)
            layer.opacity = Self.isLit(index, step: 0) ? Self.lit : Self.dim
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pitch = dotSize + gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in dots.enumerated() {
            let row = CGFloat(index / 3), column = CGFloat(index % 3)
            // Layer coordinates go up, and row 0 is the top one.
            layer.position = CGPoint(x: dotSize / 2 + column * pitch, y: dotSize / 2 + (2 - row) * pitch)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dots.forEach { $0.removeAnimation(forKey: "band") }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let period = 9 * Self.step
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let hold = CAMediaTimingFunction(name: .linear)
        // Same phase for every grid: as if they all started at time zero.
        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: period)

        for (index, layer) in dots.enumerated() {
            var values: [Float] = []
            var times: [NSNumber] = []
            var curves: [CAMediaTimingFunction] = []
            for step in 0..<9 {
                let start = Double(step) * Self.step
                let before = Self.isLit(index, step: (step + 8) % 9) ? Self.lit : Self.dim
                let after = Self.isLit(index, step: step) ? Self.lit : Self.dim
                values += [before, after]
                times += [NSNumber(value: start / period), NSNumber(value: (start + Self.fade) / period)]
                curves += step == 0 ? [ease] : [hold, ease]
            }
            // Hold the last value until the loop comes round.
            values.append(values[values.count - 1])
            times.append(1)
            curves.append(hold)

            let band = CAKeyframeAnimation(keyPath: "opacity")
            band.values = values
            band.keyTimes = times
            band.timingFunctions = curves
            band.duration = period
            band.repeatCount = .infinity
            band.timeOffset = phase
            layer.add(band, forKey: "band")
        }
    }
}
