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

/// The main switch in one line: its symbol and name (click to turn it on or off), then the
/// duration track on the right.
struct PrimaryControlRow: View {
    let module: any PerchModule

    @State private var isHovered = false

    var body: some View {
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
                    Text(module.title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(isHovered ? Ink.primary : Color.white.opacity(0.9))
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

            if module.timer != nil {
                DurationTrack(module: module, height: 30)
                    .frame(maxWidth: 296)
            }
        }
        .padding(.horizontal, NotchModel.List.rowInset)
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: module.isOn)
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

/// "∞ 15m 30m 1h 2h 4h" in one track, with a thumb in the module's color that slides to the
/// chosen segment. Picking a segment turns the module on for that long; ∞ means until you turn
/// it off. No thumb while the module is off.
struct DurationTrack: View {
    let module: any PerchModule
    var height: CGFloat = NotchModel.List.trackHeight

    @Namespace private var thumbSpace

    var body: some View {
        let selection = DurationChoice.current(for: module)

        HStack(spacing: 0) {
            ForEach(DurationChoice.all) { choice in
                DurationSegment(
                    choice: choice,
                    isSelected: selection == choice,
                    tint: module.tint,
                    thumbSpace: thumbSpace
                ) {
                    Task { await module.activate(for: choice.seconds, source: .ui) }
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
