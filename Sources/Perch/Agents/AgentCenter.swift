import AppKit
import Observation
import OSLog

/// Tracks coding agent sessions from the events `perch-hook` forwards, holds permission requests
/// until they are answered in the notch, and keeps Claude's usage limits.
@MainActor
@Observable
final class AgentCenter {
    /// Waiting for you first, then the other active ones, then the rest; in start order within
    /// each group, so rows don't jump around while several agents work.
    private(set) var sessions: [AgentSession] = []
    private(set) var usage: AgentUsage?
    private(set) var serverError: String?

    let claude: ClaudeCodeIntegration

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let hud: HUDCenter
    @ObservationIgnored private var server: AgentSocketServer?
    /// Permission requests kept open until they're answered, by approval id.
    @ObservationIgnored private var held: [UUID: HeldRequest] = [:]
    @ObservationIgnored private var cleanupTimer: Timer?
    /// Event names and session ids only (never prompts or commands): `log show --predicate 'subsystem == "com.berkkanbutun.perch"' --info`.
    @ObservationIgnored private let log = Logger(subsystem: "com.berkkanbutun.perch", category: "agents")

    static var socketPath: String {
        ProcessInfo.processInfo.environment["PERCH_SOCKET"] ?? ClaudeCodeIntegration.perchDirectory.appendingPathComponent("agent.sock").path
    }

    init(prefs: Preferences, hud: HUDCenter) {
        self.prefs = prefs
        self.hud = hud
        claude = ClaudeCodeIntegration()
    }

    var pendingApproval: AgentSession? {
        sessions.first { $0.approval != nil }
    }

    /// Sessions working or waiting for you, most important first.
    var activeSessions: [AgentSession] {
        sessions.filter { $0.state == .working || $0.state == .waiting }
    }

    // MARK: Lifecycle

    func start() {
        claude.refresh()
        claude.updateInstalledHelperIfNeeded()

        do {
            try ClaudeCodeIntegration.ensurePerchDirectory()
            let server = AgentSocketServer(path: Self.socketPath) { [weak self] line, reply in
                Task { @MainActor in self?.receive(line, reply: reply) }
            }
            try server.start()
            self.server = server
        } catch AgentSocketError.alreadyRunning {
            serverError = "Another copy of Perch is receiving agent events."
        } catch {
            serverError = "Couldn't listen for agent events (\(error))."
        }

        // Sessions that crashed never send SessionEnd; drop them after a long quiet spell.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeStaleSessions() }
        }
    }

    func stop() {
        for request in held.values { request.reply.send(nil) }
        held.removeAll()
        server?.stop()
    }

    // MARK: Actions

    /// Answers the waiting permission request. Denying Claude's questions skips them.
    func decide(_ sessionID: String, allow: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let approval = sessions[index].approval else { return }
        if let request = held.removeValue(forKey: approval.id) {
            let message = approval.questions.isEmpty ? "Denied from Perch." : "The user skipped these questions in Perch."
            // Allowing hands the input back unchanged: tools like ExitPlanMode don't run on a bare "allow".
            request.reply.send(allow
                ? Self.permissionReply(allow: true, updatedInput: request.input)
                : Self.permissionReply(allow: false, message: message))
        }
        settle(index, activity: allow ? "Approved" : approval.questions.isEmpty ? "Denied" : "Skipped")
    }

    /// Answers Claude's questions: `selections` maps each question's text to the labels picked.
    func answer(_ sessionID: String, selections: [String: Set<String>]) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let approval = sessions[index].approval, !approval.questions.isEmpty else { return }
        if let request = held.removeValue(forKey: approval.id) {
            let input = Self.answeredInput(request.input, questions: approval.questions, selections: selections)
            request.reply.send(Self.permissionReply(allow: true, updatedInput: input))
        }
        settle(index, activity: "Answered")
    }

    private func settle(_ index: Int, activity: String) {
        sessions[index].approval = nil
        sessions[index].state = .working
        sessions[index].activity = activity
        sort()
    }

    /// The hook's reply to a permission request.
    nonisolated static func permissionReply(allow: Bool, updatedInput: [String: Any]? = nil, message: String? = nil) -> Data? {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if let updatedInput { decision["updatedInput"] = updatedInput }
        if let message { decision["message"] = message }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    /// AskUserQuestion's input with `answers` added, as Claude Code expects: each question's text
    /// maps to the picked labels in Claude's order, joined with ", " when there are several.
    nonisolated static func answeredInput(_ input: [String: Any], questions: [AgentQuestion], selections: [String: Set<String>]) -> [String: Any] {
        var answers: [String: String] = [:]
        for question in questions {
            let picked = question.options.map(\.label).filter { selections[question.question]?.contains($0) == true }
            if !picked.isEmpty { answers[question.question] = picked.joined(separator: ", ") }
        }
        var updated = input
        updated["answers"] = answers
        return updated
    }

    /// Leaves the decision to the agent's own prompt in its terminal, and brings that forward.
    func answerInTerminal(_ sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        clearApproval(of: sessionID)
        TerminalJumper.jump(to: session.terminal)
    }

    func jump(to sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        TerminalJumper.jump(to: session.terminal)
    }

    func dismiss(_ sessionID: String) {
        clearApproval(of: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    // MARK: Events

    private func receive(_ line: Data, reply: AgentReply) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = message["payload"] as? [String: Any]
        else {
            reply.send(nil)
            return
        }

        switch message["kind"] as? String {
        case "statusline":
            if let usage = AgentUsage(statusLine: payload) { self.usage = usage }
            reply.send(nil)
        case "hook":
            let environment = message["env"] as? [String: String] ?? [:]
            handle(event: payload, environment: environment, reply: reply)
        default:
            reply.send(nil)
        }
    }

    private func handle(event: [String: Any], environment: [String: String], reply: AgentReply) {
        guard let name = event["hook_event_name"] as? String,
              let rawID = event["session_id"] as? String
        else {
            reply.send(nil)
            return
        }
        let id = "claude:\(rawID)"
        log.info("\(name, privacy: .public) session \(rawID.prefix(8), privacy: .public)")
        let tool = event["tool_name"] as? String ?? "Tool"
        let input = event["tool_input"] as? [String: Any] ?? [:]

        if name == "SessionEnd" {
            dismiss(id)
            reply.send(nil)
            return
        }

        var session = sessions.first { $0.id == id } ?? AgentSession(
            id: id, agent: .claude, cwd: event["cwd"] as? String ?? "",
            state: .idle, startedAt: .now, updatedAt: .now
        )
        if let cwd = event["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
        if !environment.isEmpty { session.terminal = TerminalInfo(environment: environment) }
        session.updatedAt = .now

        // Any later event means a waiting request was settled elsewhere (in the terminal, say).
        if name != "PermissionRequest", name != "Notification", let approval = session.approval {
            held.removeValue(forKey: approval.id)?.reply.send(nil)
            session.approval = nil
        }

        var keepReplyOpen = false
        switch name {
        case "SessionStart":
            session.state = .idle
            session.activity = nil
        case "UserPromptSubmit":
            if let prompt = event["prompt"] as? String {
                session.lastPrompt = ToolDescription.firstLine(prompt, limit: 120)
            }
            session.state = .working
            session.activity = "Thinking…"
            session.glance = AgentGlance(symbol: "ellipsis", text: "thinking")
        case "PreToolUse":
            session.state = .working
            session.activity = ToolDescription.activity(tool: tool, input: input)
            session.glance = ToolDescription.glance(tool: tool, input: input)
        case "PostToolUse", "PostToolUseFailure":
            session.state = .working
        case "PermissionRequest":
            if let old = session.approval { held.removeValue(forKey: old.id)?.reply.send(nil) }
            if prefs.agentApprovalsInNotch {
                let approval = PendingApproval(tool: tool, input: input)
                session.approval = approval
                held[approval.id] = HeldRequest(reply: reply, input: input)
                keepReplyOpen = true
            }
            session.state = .waiting
            session.activity = ToolDescription.activity(tool: tool, input: input)
        case "Notification":
            if event["notification_type"] as? String == "permission_prompt" {
                session.state = .waiting
            } else if event["notification_type"] as? String == "idle_prompt" {
                session.state = session.state == .done ? .done : .idle
            }
        case "Stop":
            session.state = .done
            session.activity = nil
            session.glance = nil
            if prefs.agentShowsFinished, prefs.notchShowsHUD {
                hud.show(HUDMessage(symbol: "checkmark.circle.fill", title: session.project, value: "done", tint: Palette.good))
            }
        case "StopFailure":
            session.state = .idle
            session.activity = "Stopped with an error"
        default:
            break
        }

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sort()
        if !keepReplyOpen { reply.send(nil) }
    }

    private func clearApproval(of sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let approval = sessions[index].approval else { return }
        held.removeValue(forKey: approval.id)?.reply.send(nil)
        sessions[index].approval = nil
        sessions[index].state = .working
        sort()
    }

    private func sort() {
        func rank(_ session: AgentSession) -> Int {
            if session.approval != nil { return 0 }
            switch session.state {
            case .waiting, .working: return 1
            case .done, .idle: return 2
            }
        }
        sessions.sort {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.startedAt < $1.startedAt
        }
    }

    /// Names to show: the project, plus a few words of the prompt when two sessions share one.
    static func displayNames(for sessions: [AgentSession]) -> [String: String] {
        let counts = Dictionary(grouping: sessions, by: \.project).mapValues(\.count)
        var names: [String: String] = [:]
        for session in sessions {
            guard counts[session.project, default: 0] > 1 else {
                names[session.id] = session.project
                continue
            }
            let words = session.lastPrompt?.split(separator: " ").prefix(3).joined(separator: " ")
                .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let tag = words.flatMap { $0.isEmpty ? nil : ToolDescription.firstLine($0, limit: 20) }
                ?? session.terminal?.tty.map { ($0 as NSString).lastPathComponent }
                ?? String(session.id.suffix(4))
            names[session.id] = "\(session.project) · \(tag)"
        }
        return names
    }

    var displayNames: [String: String] {
        Self.displayNames(for: sessions)
    }

    private func removeStaleSessions() {
        let cutoff = Date().addingTimeInterval(-8 * 60 * 60)
        sessions.removeAll { $0.approval == nil && $0.updatedAt < cutoff }
    }

    /// A permission request kept open until it's answered: where the answer goes, and the tool
    /// input to send back with Claude's answers.
    private struct HeldRequest {
        let reply: AgentReply
        let input: [String: Any]
    }

    #if DEBUG
    /// For snapshots: feeds an event as if it came from `perch-hook`.
    func simulate(_ event: [String: Any], environment: [String: String] = [:]) {
        handle(event: event, environment: environment, reply: AgentReply(fd: -1))
    }

    func simulateUsage(_ usage: AgentUsage) {
        self.usage = usage
    }
    #endif
}
