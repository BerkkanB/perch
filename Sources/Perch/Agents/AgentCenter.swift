import AppKit
import Observation

/// Tracks coding agent sessions from the events `perch-hook` forwards, holds permission requests
/// until they are answered in the notch, and keeps Claude's usage limits.
@MainActor
@Observable
final class AgentCenter {
    /// Waiting first, then working, then most recently active.
    private(set) var sessions: [AgentSession] = []
    private(set) var usage: AgentUsage?
    private(set) var serverError: String?

    let claude: ClaudeCodeIntegration

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let hud: HUDCenter
    @ObservationIgnored private var server: AgentSocketServer?
    @ObservationIgnored private var replies: [UUID: AgentReply] = [:]
    @ObservationIgnored private var cleanupTimer: Timer?

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
        for reply in replies.values { reply.send(nil) }
        replies.removeAll()
        server?.stop()
    }

    // MARK: Actions

    /// Answers the waiting permission request.
    func decide(_ sessionID: String, allow: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let approval = sessions[index].approval else { return }
        let decision: [String: Any] = allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied from Perch."]
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        replies.removeValue(forKey: approval.id)?.send(try? JSONSerialization.data(withJSONObject: output))
        sessions[index].approval = nil
        sessions[index].state = .working
        sessions[index].activity = allow ? "Approved" : "Denied"
        sort()
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
            replies.removeValue(forKey: approval.id)?.send(nil)
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
            if let old = session.approval { replies.removeValue(forKey: old.id)?.send(nil) }
            if prefs.agentApprovalsInNotch {
                let approval = PendingApproval(tool: tool, detail: ToolDescription.detail(tool: tool, input: input))
                session.approval = approval
                replies[approval.id] = reply
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
        replies.removeValue(forKey: approval.id)?.send(nil)
        sessions[index].approval = nil
        sessions[index].state = .working
        sort()
    }

    private func sort() {
        func rank(_ state: AgentSession.State) -> Int {
            switch state {
            case .waiting: 0
            case .working: 1
            case .done: 2
            case .idle: 3
            }
        }
        sessions.sort {
            rank($0.state) != rank($1.state) ? rank($0.state) < rank($1.state) : $0.updatedAt > $1.updatedAt
        }
    }

    private func removeStaleSessions() {
        let cutoff = Date().addingTimeInterval(-8 * 60 * 60)
        sessions.removeAll { $0.approval == nil && $0.updatedAt < cutoff }
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
