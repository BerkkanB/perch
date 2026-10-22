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
    var onSettings: (() -> Void)?

    var body: some View {
        let primary = app.primary
        let power = app.power

        HStack(spacing: 10) {
            if let usage = app.agents.usage, usage.isCurrent() {
                // Claude's limits lead, as in the agent list below.
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.stayAwake)
                UsageReadout(usage: usage)
            } else {
                Image(systemName: primary.symbol)
                    .font(.system(size: 11, weight: .bold))
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
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Perch Settings")
                .accessibilityLabel("Perch Settings")
            }
        }
        .font(Ink.stats)
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

/// The main module, written out: symbol and title, what it does, and the duration track.
struct PrimaryModuleRow: View {
    let module: any PerchModule

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await module.toggle(source: .ui) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 14) {
                        Image(systemName: module.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(module.isOn ? module.tint : Ink.tertiary)
                            .frame(width: 22, height: 22)
                            .contentTransition(.symbolEffect(.replace))
                        Text(module.title)
                            .font(Ink.title)
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: 8)
                    }
                    Text(module.caption)
                        .font(Ink.body)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .padding(.leading, 36)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(module.isBusy)
            .accessibilityLabel(module.title)
            .accessibilityValue(module.isOn ? "On" : "Off")

            if module.timer != nil {
                DurationTrack(module: module)
                    .padding(.leading, 36)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, NotchModel.List.rowInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isHovered ? Ink.hover : .clear))
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: module.isOn)
    }
}

/// "∞ 15m 30m 1h 2h 4h" in one track, with a thumb in the module's color that slides to the
/// chosen segment. Picking a segment turns the module on for that long; ∞ means until you turn
/// it off. No thumb while the module is off.
struct DurationTrack: View {
    let module: any PerchModule

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
        .frame(height: NotchModel.List.trackHeight)
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

/// Another module, in one line: a dot in its color while on, and the title.
struct CompactModuleRow: View {
    let module: any PerchModule

    @State private var isHovered = false

    var body: some View {
        Button {
            Task { await module.toggle(source: .ui) }
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(module.isOn ? module.tint : Color.white.opacity(0.25))
                    .frame(width: 8, height: 8)
                    .frame(width: 22)
                Text(module.title)
                    .font(Ink.compactTitle)
                    .foregroundStyle(Color.white.opacity(0.88))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, NotchModel.List.rowInset)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovered ? Ink.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: module.isOn)
        .help(module.caption)
        .accessibilityLabel(module.title)
        .accessibilityValue(module.isOn ? "On" : "Off")
    }
}

/// A one-line row that runs an action, styled like `CompactModuleRow`.
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
