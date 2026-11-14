import SwiftUI

// The pieces of Perch's black list, shared by the open notch and the menu bar panel.
// They are plain SwiftUI (not AppKit controls), because the notch panel never becomes key and
// AppKit controls draw dimmed in a window that isn't.

/// A small gray label, like a tag.
struct TagChip: View {
    let text: String
    var isSelected = false

    var body: some View {
        Text(text)
            .font(Ink.chipText)
            .foregroundStyle(isSelected ? Ink.primary : Color.white.opacity(0.72))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Ink.chipSelected : Ink.chip)
            )
    }
}

/// One monospaced line of readings: "☀ awake 1h12m | bat 80% 3h40m | temp cool".
struct StatsLine: View {
    @Environment(AppModel.self) private var app
    var fontSize: CGFloat = 12.5
    var onSettings: (() -> Void)?

    var body: some View {
        let primary = app.primary
        let power = app.power

        HStack(spacing: 10) {
            if let usage = app.agents.usage, usage.isCurrent() {
                // Claude's limits lead, as in the agent list below.
                Image(systemName: "sparkle")
                    .font(.system(size: fontSize - 1.5, weight: .bold))
                    .foregroundStyle(Palette.stayAwake)
                UsageReadout(usage: usage)
            } else {
                Image(systemName: primary.symbol)
                    .font(.system(size: fontSize - 1.5, weight: .bold))
                    .foregroundStyle(primary.isOn ? primary.tint : Ink.tertiary)
                HStack(spacing: 6) {
                    Text("awake").fontWeight(.bold).foregroundStyle(Ink.primary)
                    AwakeValue(module: primary)
                }
            }

            separator

            if let level = power.batteryLevel {
                reading("bat", "\(level)%", color: batteryColor(level), extra: batteryExtra)
            } else {
                reading("power", "ac", color: Palette.good, extra: nil)
            }

            if app.agents.usage?.isCurrent() != true {
                separator
                reading("temp", power.thermalState.label.lowercased(), color: thermalColor, extra: nil)
            }

            Spacer(minLength: 4)

            if let onSettings {
                StatsButton(symbol: "gearshape.fill", label: "Perch Settings", action: onSettings)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .lineLimit(1)
    }

    private var separator: some View {
        Text("|").foregroundStyle(Ink.separator)
    }

    private func reading(_ label: String, _ value: String, color: Color, extra: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.bold).foregroundStyle(Ink.primary)
            Text(value).fontWeight(.bold).foregroundStyle(color)
            if let extra {
                Text(extra).foregroundStyle(Ink.secondary)
            }
        }
    }

    private var batteryExtra: String? {
        let power = app.power
        if power.isCharging { return "charging" }
        if let remaining = power.timeRemaining { return DurationFormat.tight(remaining) }
        return power.isOnACPower ? "ac" : nil
    }

    private func batteryColor(_ level: Int) -> Color {
        if app.power.isCharging || level >= 50 { return Palette.good }
        return level >= 20 ? Palette.warning : Palette.danger
    }

    private var thermalColor: Color {
        switch app.power.thermalState {
        case .nominal: Palette.good
        case .fair: Palette.warning
        case .serious: Palette.stayAwake
        case .critical: Palette.danger
        @unknown default: Ink.secondary
        }
    }
}

/// A small gray symbol button at the end of the stats line.
private struct StatsButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? Ink.secondary : Ink.tertiary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The time left in monospaced form, "on" without a timer, "off" while off.
private struct AwakeValue: View {
    let module: any PerchModule

    var body: some View {
        if module.isOn, let end = module.timer?.endsAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DurationFormat.tight(max(0, end.timeIntervalSince(context.date))))
                    .fontWeight(.bold)
                    .foregroundStyle(module.tint)
            }
        } else {
            Text(module.isOn ? "on" : "off")
                .fontWeight(.bold)
                .foregroundStyle(module.isOn ? module.tint : Ink.secondary)
        }
    }
}

/// The switches, reachable together: the main one in a single line with its duration track,
/// then the other switches, StandBy and Sleep as tiles, three per row.
struct ControlsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: NotchModel.List.controlsGap) {
            PrimaryControlRow(module: app.primary)
                .frame(height: NotchModel.List.primaryHeight)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: NotchModel.List.tileSpacing), count: NotchModel.List.tileColumns),
                spacing: NotchModel.List.tileSpacing
            ) {
                ForEach(app.secondary, id: \.id) { module in
                    ControlTile(
                        symbol: module.symbol,
                        title: module.title,
                        status: Self.status(of: module),
                        tint: module.tint,
                        isOn: module.isOn
                    ) {
                        Task { await module.toggle(source: .ui) }
                    }
                    .help(module.caption)
                }
                ControlTile(
                    symbol: "moon.stars.fill",
                    title: "StandBy",
                    status: app.prefs.standbyRequiresAuth ? "Touch ID" : "Open",
                    tint: Palette.sleep,
                    isOn: false,
                    action: app.openStandBy
                )
                .help("A full-screen clock with your agents")
                ControlTile(
                    symbol: "powersleep",
                    title: "Sleep",
                    status: "Now",
                    tint: Palette.sleep,
                    isOn: false,
                    action: app.sleepNow
                )
                .help(app.stayAwake.isOn ? "Turns Stay Awake off and puts the Mac to sleep" : "Puts the Mac to sleep")
            }
            .padding(.horizontal, NotchModel.List.rowInset - 4)
        }
    }

    private static func status(of module: any PerchModule) -> String {
        guard module.isOn else { return "Off" }
        if let remaining = module.timer?.remaining(), module.timer?.isRunning == true {
            return "On · \(DurationFormat.tight(remaining))"
        }
        return "On"
    }
}

/// The main switch in one line: its symbol and name (click to turn it on or off), then on the
/// right the duration track. While a timer runs, the track gives way to the countdown, and the
/// end time shows under the name. Clicking the countdown brings the track back.
struct PrimaryControlRow: View {
    let module: any PerchModule

    @State private var isHovered = false
    /// The track is back over the countdown, to pick another time.
    @State private var isEditing = false
    /// The segment just picked, shown as selected while the switch turns on.
    @State private var pending: DurationChoice?

    var body: some View {
        let counting = module.isOn && module.timer?.isRunning == true && !isEditing && pending == nil

        HStack(spacing: 12) {
            Button {
                Task { await module.toggle(source: .ui) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: module.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(module.isOn ? module.tint : Ink.tertiary)
                        .frame(width: 22, height: 22)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(module.title)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(isHovered ? Ink.primary : Color.white.opacity(0.9))
                        if counting, let end = module.timer?.endsAt {
                            Text("until \(end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Ink.secondary)
                                .monospacedDigit()
                                .transition(.opacity)
                        }
                    }
                    .fixedSize()
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .disabled(module.isBusy)
            .help(module.caption)
            .accessibilityLabel(module.title)
            .accessibilityValue(module.isOn ? "On" : "Off")

            Spacer(minLength: 8)

            if let timer = module.timer {
                ZStack(alignment: .trailing) {
                    if counting {
                        CountdownControls(module: module, timer: timer) {
                            withAnimation(Self.swap) { isEditing = true }
                        }
                        .transition(Self.swapTransition)
                    } else {
                        DurationTrack(module: module, height: 30, pending: pending, onPick: pick)
                            .frame(maxWidth: 296)
                            .onHover { inside in
                                // Leaving without picking keeps the time as it was.
                                guard !inside, isEditing, pending == nil else { return }
                                withAnimation(Self.swap) { isEditing = false }
                            }
                            .transition(Self.swapTransition)
                    }
                }
            }
        }
        .padding(.horizontal, NotchModel.List.rowInset)
        .animation(Motion.hover, value: isHovered)
        .animation(Self.swap, value: counting)
        .onChange(of: module.isOn) { _, isOn in
            if !isOn { isEditing = false }
        }
    }

    private static var swap: Animation { Motion.reduceMotion ? Motion.reduced : Motion.swap }
    private static var swapTransition: AnyTransition {
        Motion.reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }

    /// Slides the thumb to `choice` at once, then swaps to the countdown once the switch is on.
    private func pick(_ choice: DurationChoice) {
        withAnimation(Motion.reduceMotion ? Motion.reduced : Motion.selection) { pending = choice }
        Task {
            await module.activate(for: choice.seconds, source: .ui)
            withAnimation(Self.swap) {
                pending = nil
                isEditing = false
            }
        }
    }
}

/// A running timer, like a Live Activity: the time left in large rolling digits (click them to
/// pick another time), +15m, and a stop button ringed by the share of time left.
struct CountdownControls: View {
    static let extendStep: TimeInterval = 15 * 60

    let module: any PerchModule
    let timer: AutoOffTimer
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date) ?? 0
            let tick = Int(remaining.rounded(.up))

            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Text(DurationFormat.clock(remaining))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(module.tint)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Motion.reduceMotion ? nil : .snappy(duration: 0.35), value: tick)
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.white.opacity(isHovered ? 0.08 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Pick another time")
                .accessibilityLabel("Time left")
                .accessibilityValue(DurationFormat.remaining(remaining))
                .accessibilityHint("Pick another time")

                TintedCapsuleButton(title: "+15m", tint: module.tint, help: "Add 15 minutes") {
                    timer.extend(by: Self.extendStep)
                }

                StopRingButton(fraction: timer.fractionRemaining(at: context.date), tick: tick, tint: module.tint) {
                    Task { await module.setOn(false, source: .ui) }
                }
            }
        }
        .disabled(module.isBusy)
        .animation(Motion.hover, value: isHovered)
    }
}

/// A capsule in a light wash of the tint, like the buttons in a Live Activity.
private struct TintedCapsuleButton: View {
    let title: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(tint.opacity(isHovered ? 0.28 : 0.17)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A round stop button whose rim shows the share of time left, like a download in the App Store.
/// The ring starts at the top and shrinks back counterclockwise.
private struct StopRingButton: View {
    let fraction: Double
    let tick: Int
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(tint.opacity(isHovered ? 0.28 : 0.17))
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.25)
                    .animation(Motion.reduceMotion ? nil : .linear(duration: 1), value: tick)
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help("Turn Stay Awake off")
        .accessibilityLabel("Turn Stay Awake off")
    }
}

/// A Control Center–style tile: a round symbol (filled with the tint while on), a title and a
/// short state. The whole tile is one button.
struct ControlTile: View {
    let symbol: String
    let title: String
    let status: String
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isOn ? tint : Color.white.opacity(0.1)))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(isOn ? tint : Ink.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: NotchModel.List.tileHeight)
            .background(shape.fill(isOn ? tint.opacity(0.16) : Color.white.opacity(isHovered ? 0.09 : 0.06)))
            .overlay(shape.strokeBorder(isOn ? tint.opacity(0.35) : Color.white.opacity(0.05), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(status)
    }
}

/// Startup disk and memory as two gauges under the switches. Storage opens its pane in System
/// Settings, Memory opens Activity Monitor.
struct SystemReadings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: NotchModel.List.tileSpacing) {
            if let storage = app.system.storage {
                GaugeTile(
                    symbol: "internaldrive.fill",
                    title: "Storage",
                    value: "\(ByteFormat.storage(storage.available)) free",
                    fraction: storage.usedFraction,
                    tint: Self.color(for: storage.level),
                    isAlert: storage.level != .ok,
                    help: "\(ByteFormat.storage(storage.used)) of \(ByteFormat.storage(storage.total)) used. Click to see what takes up space.",
                    action: openStorageSettings
                )
            }
            if let memory = app.system.memory {
                GaugeTile(
                    symbol: "memorychip.fill",
                    title: "Memory",
                    value: ByteFormat.memory(memory.used, of: memory.total),
                    shortValue: ByteFormat.memory(memory.used),
                    fraction: memory.usedFraction,
                    tint: Self.color(for: memory.pressure),
                    isAlert: memory.pressure != .normal,
                    help: memoryHelp(memory),
                    action: openActivityMonitor
                )
            }
        }
        .padding(.horizontal, NotchModel.List.rowInset - 4)
        .frame(height: NotchModel.List.tileHeight)
    }

    private func memoryHelp(_ memory: MemoryReading) -> String {
        var text = "Memory pressure \(memory.pressure.label.lowercased())"
        if memory.swapUsed > 0 { text += ", \(ByteFormat.memory(memory.swapUsed)) swap" }
        return text + ". Click to open Activity Monitor."
    }

    private func openStorageSettings() {
        app.closeTransientUI()
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openActivityMonitor() {
        app.closeTransientUI()
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func color(for level: StorageReading.Level) -> Color {
        switch level {
        case .ok: Palette.good
        case .low: Palette.warning
        case .critical: Palette.danger
        }
    }

    private static func color(for pressure: MemoryReading.Pressure) -> Color {
        switch pressure {
        case .normal: Palette.good
        case .warning: Palette.warning
        case .critical: Palette.danger
        }
    }
}

/// A tile with a reading and a thin bar under it: "Storage · 82 GB free", the bar filled to how
/// much is used. The symbol takes the bar's color only when the reading needs attention.
struct GaugeTile: View {
    let symbol: String
    let title: String
    let value: String
    /// Shown instead of `value` where it doesn't fit, as in the narrower menu bar panel.
    var shortValue: String?
    let fraction: Double
    let tint: Color
    let isAlert: Bool
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isAlert ? tint : Color.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isAlert ? tint.opacity(0.18) : Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .fixedSize()
                        Spacer(minLength: 4)
                        ViewThatFits(in: .horizontal) {
                            Text(value)
                            if let shortValue { Text(shortValue) }
                        }
                        .font(.system(size: 11.5, weight: isAlert ? .semibold : .regular))
                        .foregroundStyle(isAlert ? tint : Ink.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    }
                    .lineLimit(1)
                    GaugeBar(fraction: fraction, tint: tint)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Color.white.opacity(isHovered ? 0.09 : 0.06)))
            .overlay(shape.strokeBorder(isAlert ? tint.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.3), value: value)
        .animation(.easeInOut(duration: 0.3), value: isAlert)
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(help)
        .accessibilityAddTraits(.isButton)
    }
}

/// A thin capsule filled to `fraction`.
private struct GaugeBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.white.opacity(0.1))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        // Never thinner than its own height, so a near-empty bar still reads as a dot.
                        .frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
                }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}

/// "∞ 15m 30m 1h 2h 4h" in one track, with a thumb in the module's color that slides to the
/// chosen segment. Picking a segment turns the module on for that long; ∞ means until you turn
/// it off. No thumb while the module is off.
struct DurationTrack: View {
    let module: any PerchModule
    var height: CGFloat = NotchModel.List.trackHeight
    /// Shown as selected while the switch is still turning on.
    var pending: DurationChoice?
    /// Replaces turning the module on directly.
    var onPick: ((DurationChoice) -> Void)?

    @Namespace private var thumbSpace

    var body: some View {
        let selection = pending ?? DurationChoice.current(for: module)

        HStack(spacing: 0) {
            ForEach(DurationChoice.all) { choice in
                DurationSegment(
                    choice: choice,
                    isSelected: selection == choice,
                    tint: module.tint,
                    thumbSpace: thumbSpace
                ) {
                    if let onPick {
                        onPick(choice)
                    } else {
                        Task { await module.activate(for: choice.seconds, source: .ui) }
                    }
                }
            }
        }
        .padding(3)
        .frame(height: height)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .disabled(module.isBusy)
        .animation(Motion.selection, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn off after")
    }
}

private struct DurationSegment: View {
    let choice: DurationChoice
    let isSelected: Bool
    let tint: Color
    let thumbSpace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if choice == .never {
                    Image(systemName: "infinity")
                        .font(.system(size: 12.5, weight: .bold))
                } else {
                    Text(choice.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isSelected ? Color.black.opacity(0.82) : Color.white.opacity(isHovered ? 0.95 : 0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(tint)
                        .matchedGeometryEffect(id: "thumb", in: thumbSpace)
                } else if isHovered {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(choice.seconds.map { "On for \(DurationFormat.preset($0))" } ?? "On until you turn it off")
        .accessibilityLabel(choice.seconds.map { "On for \(DurationFormat.preset($0))" } ?? "On until you turn it off")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A one-line row that runs an action, such as Settings.
struct ActionRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var tint: Color = Ink.secondary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(title)
                    .font(Ink.compactTitle)
                    .foregroundStyle(Color.white.opacity(0.88))
                Spacer(minLength: 8)
                if let detail {
                    TagChip(text: detail)
                }
            }
            .padding(.horizontal, NotchModel.List.rowInset)
            .frame(height: NotchModel.List.rowHeight)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovered ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
    }
}
