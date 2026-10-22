import AppKit
import SwiftUI

private typealias Layout = NotchModel.List

extension AgentSession.State {
    /// Blue while working, orange while it needs you, green when done.
    var color: Color {
        switch self {
        case .working: Color.blue
        case .waiting: Palette.stayAwake
        case .done: Palette.good
        case .idle: Color.white.opacity(0.3)
        }
    }
}

/// The coding agent sessions: the most important one written out, the rest one line each.
struct AgentSessionList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.agentListWidth) private var listWidth

    var body: some View {
        let sessions = app.agents.sessions
        let names = app.agents.displayNames

        if let first = sessions.first {
            VStack(spacing: Layout.rowSpacing) {
                AgentSessionCard(session: first, name: names[first.id] ?? first.project)
                    .frame(height: Layout.sessionCardHeight(for: first, listWidth: listWidth), alignment: .top)

                ForEach(sessions.dropFirst().prefix(Layout.maxCompactSessions)) { session in
                    AgentSessionRow(session: session, name: names[session.id] ?? session.project)
                        .frame(height: Layout.rowHeight)
                }

                let hidden = sessions.count - 1 - Layout.maxCompactSessions
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(Ink.body)
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Layout.rowInset + 36)
                        .frame(height: Layout.moreRowHeight)
                }
            }
        }
    }
}

/// A session written out: project, your last prompt, what it's doing in its state color, and
/// Allow / Deny when it needs approval (or Claude's questions). Clicking it brings its terminal
/// forward.
struct AgentSessionCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.agentsInteractive) private var isInteractive
    let session: AgentSession
    let name: String

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 14) {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(session.state.color)
                    .frame(width: 22, height: 22)
                Text(name)
                    .font(Ink.title)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SessionMeta(session: session)
            }

            Group {
                Text(session.lastPrompt.map { "You: \($0)" } ?? "No prompt yet")
                    .foregroundStyle(Ink.secondary)
                Text(session.statusText)
                    .foregroundStyle(session.state == .idle ? Ink.secondary : session.state.color)
            }
            .font(Ink.body)
            .lineLimit(1)
            .padding(.leading, Layout.cardIndent)

            if let approval = session.approval {
                ApprovalBox(session: session, approval: approval)
                    .id(approval.id)
                    .padding(.leading, Layout.cardIndent)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isHovered ? Ink.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.agents.jump(to: session.id) }
        .allowsHitTesting(isInteractive || session.approval != nil)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: session.state)
        .help("Show in \(session.terminal?.appName ?? "its terminal")")
    }
}

/// One line per other session: a dot in its state color, the name, what it's doing now, age.
struct AgentSessionRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.agentsInteractive) private var isInteractive
    let session: AgentSession
    let name: String

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(session.state.color)
                .frame(width: 8, height: 8)
                .frame(width: 22)
            Text(name)
                .font(Ink.compactTitle)
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            GlanceLabel(session: session)
            AgeText(since: session.startedAt)
        }
        .padding(.horizontal, Layout.rowInset)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovered ? Ink.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.agents.jump(to: session.id) }
        .allowsHitTesting(isInteractive)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(session.statusText)
    }
}

/// "[Claude] [Ghostty] 27m", with one chip when the agent runs in its own app.
private struct SessionMeta: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            TagChip(text: session.agent.displayName)
            if let terminal = session.terminal?.appName, terminal != session.agent.displayName {
                TagChip(text: terminal)
            }
            AgeText(since: session.startedAt)
        }
    }
}

/// "✎ middleware.ts" in the session's state color: what it's doing right now.
struct GlanceLabel: View {
    let session: AgentSession

    var body: some View {
        let glance = session.badgeGlance
        HStack(spacing: 5) {
            Image(systemName: glance.symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text(glance.text)
                .font(Ink.body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(session.state == .idle || session.state == .done ? Ink.secondary : session.state.color)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.2), value: glance)
    }
}

/// How long ago a session started: "now", "27m", "1h".
private struct AgeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let age = context.date.timeIntervalSince(since)
            Text(age < 60 ? "now" : DurationFormat.tight(age))
                .font(Ink.body)
                .foregroundStyle(Ink.tertiary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }
}

/// What the agent wants to run, with Allow and Deny, or Claude's questions with Submit.
/// "Answer in Terminal" leaves it to the agent's own prompt (to type your own answer, say) and
/// brings its terminal forward.
private struct ApprovalBox: View {
    @Environment(AppModel.self) private var app
    @Environment(\.agentsInteractive) private var isInteractive
    @Environment(\.agentListWidth) private var listWidth
    let session: AgentSession
    let approval: PendingApproval

    /// Each question's text, with the labels picked for it.
    @State private var selections: [String: Set<String>] = [:]

    var body: some View {
        let width = Layout.approvalWidth(listWidth: listWidth)

        VStack(alignment: .leading, spacing: 8) {
            if approval.questions.isEmpty {
                ToolRequest(approval: approval, width: width)
            } else {
                QuestionList(questions: approval.questions, selections: $selections, width: width)
                    .disabled(!isInteractive)
            }

            if !isInteractive {
                Text("Close StandBy to answer")
                    .font(Ink.body)
                    .foregroundStyle(Ink.secondary)
                    .frame(height: Layout.approvalButtonsHeight)
            } else {
                HStack(spacing: 8) {
                    Button("Answer in Terminal") { app.agents.answerInTerminal(session.id) }
                        .buttonStyle(.plain)
                        .font(Ink.body)
                        .foregroundStyle(Ink.secondary)
                    Spacer()
                    if approval.questions.isEmpty {
                        ApprovalButton(title: "Deny", isProminent: false) { app.agents.decide(session.id, allow: false) }
                        ApprovalButton(title: "Allow", isProminent: true) { app.agents.decide(session.id, allow: true) }
                    } else {
                        ApprovalButton(title: "Skip", isProminent: false) { app.agents.decide(session.id, allow: false) }
                        ApprovalButton(title: "Submit", isProminent: true, isEnabled: isAnswered) {
                            app.agents.answer(session.id, selections: selections)
                        }
                    }
                }
                .frame(height: Layout.approvalButtonsHeight)
            }
        }
        // Clicks between the options shouldn't fall through to the card and switch apps.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var isAnswered: Bool {
        approval.questions.allSatisfy { selections[$0.question]?.isEmpty == false }
    }
}

/// The tool and its command, file or plan in full, scrolling when it's long.
private struct ToolRequest: View {
    let approval: PendingApproval
    let width: CGFloat

    var body: some View {
        let detail = Layout.detailHeight(approval.detail, width: width)

        VStack(alignment: .leading, spacing: ApprovalStyle.detailGap) {
            HStack(spacing: 8) {
                Text(approval.tool)
                    .font(.system(size: ApprovalStyle.codeSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.stayAwake)
                if let summary = approval.summary {
                    Text(summary)
                        .font(.system(size: ApprovalStyle.codeSize))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: ApprovalStyle.toolLineHeight)

            if !approval.detail.isEmpty {
                FadingScroll(isOverflowing: detail.isOverflowing) {
                    Text(approval.detail)
                        .font(.system(size: ApprovalStyle.codeSize, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: detail.visible)
            }
        }
        .padding(ApprovalStyle.boxPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// Claude's questions, one after another, each with its options to pick from.
private struct QuestionList: View {
    let questions: [AgentQuestion]
    @Binding var selections: [String: Set<String>]
    let width: CGFloat

    var body: some View {
        let height = Layout.questionsHeight(questions, width: width)

        FadingScroll(isOverflowing: height.isOverflowing) {
            VStack(alignment: .leading, spacing: ApprovalStyle.questionSpacing) {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    QuestionView(question: question, selected: selection(for: question))
                }
            }
        }
        .frame(height: height.visible)
    }

    private func selection(for question: AgentQuestion) -> Binding<Set<String>> {
        Binding(
            get: { selections[question.question] ?? [] },
            set: { selections[question.question] = $0 }
        )
    }
}

/// "VERSION · PICK ONE", the question, then its options as radio buttons, or checkboxes when
/// several can be picked.
private struct QuestionView: View {
    let question: AgentQuestion
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .frame(height: ApprovalStyle.captionHeight)

            Text(question.question)
                .font(.system(size: ApprovalStyle.questionSize, weight: .medium))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, ApprovalStyle.captionGap)

            VStack(spacing: ApprovalStyle.optionSpacing) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    OptionRow(option: option, isMultiSelect: question.multiSelect, isSelected: selected.contains(option.label)) {
                        toggle(option.label)
                    }
                }
            }
            .padding(.top, ApprovalStyle.optionsGap)
        }
    }

    private var caption: String {
        let hint = question.multiSelect ? "PICK ANY" : "PICK ONE"
        return question.header.isEmpty ? hint : "\(question.header.uppercased()) · \(hint)"
    }

    private func toggle(_ label: String) {
        if question.multiSelect {
            if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
        } else {
            selected = [label]
        }
    }
}

private struct OptionRow: View {
    let option: AgentQuestion.Option
    let isMultiSelect: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: ApprovalStyle.indicatorGap) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Palette.stayAwake : Ink.tertiary)
                    .frame(width: ApprovalStyle.indicatorWidth)
                VStack(alignment: .leading, spacing: ApprovalStyle.descriptionGap) {
                    Text(option.label)
                        .font(.system(size: ApprovalStyle.labelSize, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: ApprovalStyle.descriptionSize))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, ApprovalStyle.optionPadding.width)
            .padding(.vertical, ApprovalStyle.optionPadding.height)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.13 : isHovered ? 0.08 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(Motion.selection, value: isSelected)
    }

    private var symbol: String {
        if isMultiSelect { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

/// A vertical scroll view that fades out at the bottom while there's more to scroll to.
private struct FadingScroll<Content: View>: View {
    let isOverflowing: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.bottom, isOverflowing ? ApprovalStyle.fade : 0)
        }
        .scrollBounceBehavior(.basedOnSize)
        .mask {
            VStack(spacing: 0) {
                Color.black
                if isOverflowing {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: ApprovalStyle.fade)
                }
            }
        }
    }
}

private struct ApprovalButton: View {
    let title: String
    let isProminent: Bool
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : Ink.primary)
                .padding(.horizontal, 18)
                .frame(height: Layout.approvalButtonsHeight)
                .background(
                    Capsule().fill(isProminent ? Color.white.opacity(isHovered && isEnabled ? 0.85 : 1) : Color.white.opacity(isHovered ? 0.18 : 0.12))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(Motion.selection, value: isEnabled)
    }
}

// MARK: Sizes

/// The approval box's text sizes and spacing, shared by the views above and the heights below,
/// so the notch opens exactly as tall as its content.
private enum ApprovalStyle {
    static let codeSize: CGFloat = 12
    static let questionSize: CGFloat = 13.5
    static let labelSize: CGFloat = 13
    static let descriptionSize: CGFloat = 12

    static let boxPadding: CGFloat = 10
    static let toolLineHeight: CGFloat = 15
    static let detailGap: CGFloat = 6
    /// Longer commands and plans scroll.
    static let maxDetailHeight: CGFloat = 220

    static let captionHeight: CGFloat = 14
    static let captionGap: CGFloat = 3
    static let optionsGap: CGFloat = 8
    static let optionSpacing: CGFloat = 4
    static let optionPadding = CGSize(width: 10, height: 7)
    static let indicatorWidth: CGFloat = 16
    static let indicatorGap: CGFloat = 9
    static let descriptionGap: CGFloat = 1
    static let questionSpacing: CGFloat = 16
    /// More questions than this scroll.
    static let maxQuestionsHeight: CGFloat = 360

    static let fade: CGFloat = 18
}

extension NotchModel.List {
    /// How far the session card's lines and approval box sit in from its symbol.
    static let cardIndent: CGFloat = 36

    /// The written-out session: its lines, plus its approval or questions laid out at `listWidth`.
    static func sessionCardHeight(for session: AgentSession, listWidth: CGFloat) -> CGFloat {
        let base: CGFloat = 82
        guard let approval = session.approval else { return base }
        let width = approvalWidth(listWidth: listWidth)
        let content = approval.questions.isEmpty
            ? toolRequestHeight(approval, width: width)
            : questionsHeight(approval.questions, width: width).visible
        return base + 8 + content + 8 + approvalButtonsHeight
    }

    static func approvalWidth(listWidth: CGFloat) -> CGFloat {
        listWidth - 2 * rowInset - cardIndent
    }

    /// How tall a scrolling block is, and whether its content goes on past that.
    struct ScrollHeight {
        var visible: CGFloat
        var isOverflowing: Bool

        init(content: CGFloat, limit: CGFloat) {
            visible = min(content, limit)
            isOverflowing = content > limit
        }
    }

    fileprivate static func toolRequestHeight(_ approval: PendingApproval, width: CGFloat) -> CGFloat {
        var height = 2 * ApprovalStyle.boxPadding + ApprovalStyle.toolLineHeight
        if !approval.detail.isEmpty {
            height += ApprovalStyle.detailGap + detailHeight(approval.detail, width: width).visible
        }
        return height
    }

    fileprivate static func detailHeight(_ detail: String, width: CGFloat) -> ScrollHeight {
        let font = NSFont.monospacedSystemFont(ofSize: ApprovalStyle.codeSize, weight: .regular)
        let content = textHeight(detail, font: font, width: width - 2 * ApprovalStyle.boxPadding)
        return ScrollHeight(content: content, limit: ApprovalStyle.maxDetailHeight)
    }

    fileprivate static func questionsHeight(_ questions: [AgentQuestion], width: CGFloat) -> ScrollHeight {
        let questionFont = NSFont.systemFont(ofSize: ApprovalStyle.questionSize, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: ApprovalStyle.labelSize, weight: .semibold)
        let descriptionFont = NSFont.systemFont(ofSize: ApprovalStyle.descriptionSize)
        let textWidth = width - 2 * ApprovalStyle.optionPadding.width - ApprovalStyle.indicatorWidth - ApprovalStyle.indicatorGap

        let blocks = questions.map { question -> CGFloat in
            let options = question.options.map { option -> CGFloat in
                var height = 2 * ApprovalStyle.optionPadding.height + textHeight(option.label, font: labelFont, width: textWidth)
                if !option.description.isEmpty {
                    height += ApprovalStyle.descriptionGap + textHeight(option.description, font: descriptionFont, width: textWidth)
                }
                return height
            }
            return ApprovalStyle.captionHeight + ApprovalStyle.captionGap
                + textHeight(question.question, font: questionFont, width: width)
                + ApprovalStyle.optionsGap
                + options.reduce(0, +) + CGFloat(max(0, options.count - 1)) * ApprovalStyle.optionSpacing
        }
        let content = blocks.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * ApprovalStyle.questionSpacing
        return ScrollHeight(content: content, limit: ApprovalStyle.maxQuestionsHeight)
    }

    /// The height `text` wraps to at `width`.
    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height)
    }
}

private struct AgentListWidthKey: EnvironmentKey {
    static let defaultValue = NotchModel.expandedWidth - 2 * NotchModel.List.panelInset
}

extension EnvironmentValues {
    /// The width the agent list is laid out at, which decides how tall long questions wrap to.
    var agentListWidth: CGFloat {
        get { self[AgentListWidthKey.self] }
        set { self[AgentListWidthKey.self] = newValue }
    }
}

/// "✦ 5h 11% 4h1m | 7d 2% 6h1m": Claude's 5-hour and weekly limits, used share and time to reset.
struct UsageReadout: View {
    let usage: AgentUsage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                if let window = usage.fiveHour, window.resetsAt > context.date {
                    reading("5h", window, now: context.date)
                }
                if let fiveHour = usage.fiveHour, fiveHour.resetsAt > context.date,
                   let sevenDay = usage.sevenDay, sevenDay.resetsAt > context.date {
                    Text("|").foregroundStyle(Ink.separator)
                }
                if let window = usage.sevenDay, window.resetsAt > context.date {
                    reading("7d", window, now: context.date)
                }
            }
        }
    }

    private func reading(_ label: String, _ window: AgentUsage.Window, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(.bold).foregroundStyle(Ink.primary)
            Text("\(Int(window.usedPercent.rounded()))%").fontWeight(.bold).foregroundStyle(color(for: window.usedPercent))
            Text(DurationFormat.tight(window.resetsAt.timeIntervalSince(now))).foregroundStyle(Ink.secondary)
        }
    }

    private func color(for percent: Double) -> Color {
        if percent < 50 { return Palette.good }
        return percent < 80 ? Palette.warning : Palette.danger
    }
}

extension AgentUsage {
    /// Whether any window is still current.
    func isCurrent(at date: Date = .now) -> Bool {
        [fiveHour, sevenDay].contains { ($0?.resetsAt ?? .distantPast) > date }
    }
}
