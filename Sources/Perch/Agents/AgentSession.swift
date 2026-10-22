import AppKit
import Foundation

/// One coding agent session, built up from its hook events.
struct AgentSession: Identifiable, Equatable {
    enum State: Equatable {
        /// Started, or waiting for your next prompt.
        case idle
        /// Thinking or using tools.
        case working
        /// Needs your approval.
        case waiting
        /// Finished its last turn.
        case done
    }

    /// `source:session_id`, e.g. `claude:1f3a…`.
    let id: String
    let agent: AgentKind
    var cwd: String
    var lastPrompt: String?
    /// What it is doing right now, e.g. "Writing middleware.ts".
    var activity: String?
    /// The same, shortened for beside the notch: a symbol and the file or command.
    var glance: AgentGlance?
    var state: State
    var startedAt: Date
    var updatedAt: Date
    var terminal: TerminalInfo?
    var approval: PendingApproval?

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? agent.displayName : name
    }

    /// What the collapsed notch shows for this session.
    var badgeGlance: AgentGlance {
        switch state {
        case .waiting: AgentGlance(symbol: "hand.raised.fill", text: "needs you")
        case .done: AgentGlance(symbol: "checkmark", text: "done")
        case .idle: AgentGlance(symbol: "pause.fill", text: "idle")
        case .working: glance ?? AgentGlance(symbol: "ellipsis", text: "working")
        }
    }

    /// The line under the prompt: what it's doing, or its state.
    var statusText: String {
        switch state {
        case .waiting: approval.map { "Needs approval · \($0.tool)" } ?? "Needs your approval"
        case .working: activity ?? "Working…"
        case .done: "Done"
        case .idle: "Waiting for your prompt"
        }
    }
}

enum AgentKind: String, Equatable {
    case claude

    var displayName: String {
        switch self {
        case .claude: "Claude"
        }
    }
}

/// A very short "what": a symbol and a file name, command or word.
struct AgentGlance: Equatable {
    var symbol: String
    var text: String
}

/// A tool call waiting for Allow or Deny.
struct PendingApproval: Equatable {
    let id = UUID()
    var tool: String
    /// The command, file or URL it wants to use.
    var detail: String
}

/// The terminal (or editor) an agent runs in, from the environment its hook ran with.
struct TerminalInfo: Equatable {
    var bundleID: String?
    var termProgram: String?
    var tty: String?
    var tmuxPane: String?

    init(environment: [String: String]) {
        termProgram = environment["TERM_PROGRAM"]
        tty = environment["tty"]
        tmuxPane = environment["TMUX_PANE"]
        bundleID = environment["__CFBundleIdentifier"] ?? Self.bundleID(forTermProgram: termProgram)
    }

    /// The app's name, e.g. "Ghostty".
    @MainActor var appName: String? {
        if let bundleID, let name = Self.appName(for: bundleID) { return name }
        return termProgram.map(Self.prettyTermProgram)
    }

    static func bundleID(forTermProgram program: String?) -> String? {
        switch program {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "ghostty": "com.mitchellh.ghostty"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "WezTerm": "com.github.wez.wezterm"
        default: nil
        }
    }

    private static func prettyTermProgram(_ program: String) -> String {
        switch program {
        case "Apple_Terminal": "Terminal"
        case "iTerm.app": "iTerm"
        case "ghostty": "Ghostty"
        case "WarpTerminal": "Warp"
        case "vscode": "VS Code"
        default: program
        }
    }

    @MainActor private static var nameCache: [String: String] = [:]

    @MainActor private static func appName(for bundleID: String) -> String? {
        if let cached = nameCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        nameCache[bundleID] = name
        return name
    }
}

/// Claude's subscription limits, from the status line data Claude Code passes to Perch.
struct AgentUsage: Equatable {
    struct Window: Equatable {
        /// 0–100.
        var usedPercent: Double
        var resetsAt: Date
    }

    var fiveHour: Window?
    var sevenDay: Window?

    init(fiveHour: Window?, sevenDay: Window?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// Reads `rate_limits.five_hour` and `rate_limits.seven_day` from the status line JSON.
    init?(statusLine payload: [String: Any]) {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let raw = limits[key] as? [String: Any],
                  let used = (raw["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (raw["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        fiveHour = window("five_hour")
        sevenDay = window("seven_day")
        if fiveHour == nil, sevenDay == nil { return nil }
    }
}

/// Short descriptions of tool calls, for the session card and approvals.
enum ToolDescription {
    /// "Writing middleware.ts", "Running npm test", …
    static func activity(tool: String, input: [String: Any]) -> String {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            return "Running \(firstLine(input["command"] as? String ?? "a command", limit: 44))"
        case "Edit", "MultiEdit":
            return "Editing \(file ?? "a file")"
        case "Write":
            return "Writing \(file ?? "a file")"
        case "Read":
            return "Reading \(file ?? "a file")"
        case "NotebookEdit":
            return "Editing \(file ?? "a notebook")"
        case "Grep":
            return "Searching for “\(firstLine(input["pattern"] as? String ?? "", limit: 30))”"
        case "Glob":
            return "Finding \(firstLine(input["pattern"] as? String ?? "files", limit: 36))"
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page"
            return "Fetching \(host)"
        case "WebSearch":
            return "Searching the web"
        case "Task", "Agent":
            return "Running a subagent"
        case "TodoWrite":
            return "Updating its plan"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return "Using \(parts.last.map(String.init) ?? tool)"
            }
            return "Using \(tool)"
        }
    }

    /// For beside the notch: ✎ middleware.ts, a terminal symbol with "npm run dev", …
    static func glance(tool: String, input: [String: Any]) -> AgentGlance {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            return AgentGlance(symbol: "terminal", text: firstLine(input["command"] as? String ?? "command", limit: 40))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return AgentGlance(symbol: "pencil", text: file ?? "file")
        case "Read":
            return AgentGlance(symbol: "doc.text", text: file ?? "file")
        case "Grep", "Glob":
            return AgentGlance(symbol: "magnifyingglass", text: firstLine(input["pattern"] as? String ?? "search", limit: 40))
        case "WebFetch":
            return AgentGlance(symbol: "globe", text: (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "web")
        case "WebSearch":
            return AgentGlance(symbol: "globe", text: "web search")
        case "Task", "Agent":
            return AgentGlance(symbol: "person.2", text: "subagent")
        case "TodoWrite":
            return AgentGlance(symbol: "checklist", text: "plan")
        default:
            let name = tool.hasPrefix("mcp__") ? tool.split(separator: "_").last.map(String.init) ?? tool : tool
            return AgentGlance(symbol: "hammer", text: name)
        }
    }

    /// What an approval is about: the command, file or URL.
    static func detail(tool: String, input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "url", "query", "pattern"] {
            if let value = input[key] as? String, !value.isEmpty {
                return firstLine(value, limit: 160)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return tool }
        return firstLine(json, limit: 160)
    }

    static func firstLine(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}
