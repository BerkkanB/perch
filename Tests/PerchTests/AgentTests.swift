import XCTest
@testable import Perch

final class ClaudeSettingsTests: XCTestCase {
    private let helper = "/Users/me/.perch/bin/perch-hook"

    func testConnectAddsEveryEventAndTheStatusLine() {
        let settings = ClaudeCodeIntegration.addingPerch(to: ["theme": "dark"], helperPath: helper)
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in ClaudeCodeIntegration.toolEvents + ClaudeCodeIntegration.otherEvents {
            XCTAssertNotNil(hooks[event], event)
        }
        let permission = (hooks["PermissionRequest"] as? [[String: Any]])?.first
        XCTAssertEqual(permission?["matcher"] as? String, "*")
        let handler = (permission?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(handler?["command"] as? String, "'\(helper)' claude")
        XCTAssertEqual(handler?["timeout"] as? Int, 600)
        XCTAssertEqual(ClaudeCodeIntegration.statusLineCommand(in: settings), "'\(helper)' statusline")
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertTrue(ClaudeCodeIntegration.containsPerch(settings))
    }

    func testConnectKeepsTheUsersOwnHooksAndDoesNotDuplicate() {
        let own: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "./guard.sh"]]]]]]
        let once = ClaudeCodeIntegration.addingPerch(to: own, helperPath: helper)
        let twice = ClaudeCodeIntegration.addingPerch(to: once, helperPath: helper)
        let groups = (twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(groups.count, 2, "the user's group plus one of Perch's")
        XCTAssertEqual(groups.first?["matcher"] as? String, "Bash")
    }

    func testDisconnectRemovesOnlyPerchAndRestoresTheStatusLine() {
        let own: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
            "statusLine": ["type": "command", "command": "~/bin/line.sh"],
        ]
        let connected = ClaudeCodeIntegration.addingPerch(to: own, helperPath: helper)
        let restored = ClaudeCodeIntegration.removingPerch(from: connected, restoringStatusLine: "~/bin/line.sh")
        XCTAssertFalse(ClaudeCodeIntegration.containsPerch(restored))
        let stop = (restored["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1)
        XCTAssertNil((restored["hooks"] as? [String: Any])?["PreToolUse"])
        XCTAssertEqual(ClaudeCodeIntegration.statusLineCommand(in: restored), "~/bin/line.sh")
    }

    func testDisconnectWithoutAnEarlierStatusLineRemovesIt() {
        let connected = ClaudeCodeIntegration.addingPerch(to: [:], helperPath: helper)
        let cleaned = ClaudeCodeIntegration.removingPerch(from: connected, restoringStatusLine: nil)
        XCTAssertNil(cleaned["statusLine"])
        XCTAssertNil(cleaned["hooks"])
    }
}

final class AgentEventTests: XCTestCase {
    func testToolDescriptions() {
        XCTAssertEqual(ToolDescription.activity(tool: "Write", input: ["file_path": "/src/middleware.ts"]), "Writing middleware.ts")
        XCTAssertEqual(ToolDescription.activity(tool: "Bash", input: ["command": "npm test\necho done"]), "Running npm test")
        XCTAssertEqual(ToolDescription.activity(tool: "WebFetch", input: ["url": "https://example.com/a"]), "Fetching example.com")
        XCTAssertEqual(ToolDescription.activity(tool: "mcp__github__create_issue", input: [:]), "Using issue")
        XCTAssertEqual(ToolDescription.detail(tool: "Bash", input: ["command": "rm -rf build"]), "rm -rf build")
    }

    func testGlances() {
        XCTAssertEqual(ToolDescription.glance(tool: "Edit", input: ["file_path": "/a/middleware.ts"]), AgentGlance(symbol: "pencil", text: "middleware.ts"))
        XCTAssertEqual(ToolDescription.glance(tool: "Bash", input: ["command": "npm run dev"]), AgentGlance(symbol: "terminal", text: "npm run dev"))
        XCTAssertEqual(ToolDescription.glance(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]).text, "docs.swift.org")
    }

    func testUsageFromStatusLine() throws {
        let payload: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 11.4, "resets_at": 1_800_000_000],
            "seven_day": ["used_percentage": 2, "resets_at": 1_800_500_000],
        ]]
        let usage = try XCTUnwrap(AgentUsage(statusLine: payload))
        XCTAssertEqual(usage.fiveHour?.usedPercent ?? 0, 11.4, accuracy: 0.001)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_800_500_000))
        XCTAssertNil(AgentUsage(statusLine: ["model": ["display_name": "Opus"]]))
    }

    @MainActor
    func testSessionLifecycle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "perch.tests.\(UUID().uuidString)"))
        let center = AgentCenter(prefs: Preferences(defaults: defaults), hud: HUDCenter())
        let env = ["__CFBundleIdentifier": "com.mitchellh.ghostty"]

        center.simulate(["hook_event_name": "SessionStart", "session_id": "a", "cwd": "/code/api"], environment: env)
        center.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "a", "prompt": "fix the auth bug in middleware"])
        center.simulate(["hook_event_name": "PreToolUse", "session_id": "a", "tool_name": "Write", "tool_input": ["file_path": "/code/api/middleware.ts"]])

        var session = try XCTUnwrap(center.sessions.first)
        XCTAssertEqual(session.project, "api")
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.statusText, "Writing middleware.ts")
        XCTAssertEqual(session.lastPrompt, "fix the auth bug in middleware")
        XCTAssertEqual(session.terminal?.bundleID, "com.mitchellh.ghostty")

        // A second, finished session sorts below the working one.
        center.simulate(["hook_event_name": "Stop", "session_id": "b", "cwd": "/code/web"])
        XCTAssertEqual(center.sessions.map(\.project), ["api", "web"])

        // A permission request waits, and moves its session to the top.
        center.simulate(["hook_event_name": "PermissionRequest", "session_id": "b", "tool_name": "Bash", "tool_input": ["command": "npm install lodash"]])
        XCTAssertEqual(center.pendingApproval?.project, "web")
        XCTAssertEqual(center.pendingApproval?.approval?.detail, "npm install lodash")

        // The next event for that session means it was answered elsewhere.
        center.simulate(["hook_event_name": "PostToolUse", "session_id": "b", "tool_name": "Bash"])
        XCTAssertNil(center.pendingApproval)

        center.simulate(["hook_event_name": "Stop", "session_id": "a"])
        session = try XCTUnwrap(center.sessions.first { $0.project == "api" })
        XCTAssertEqual(session.state, .done)

        center.simulate(["hook_event_name": "SessionEnd", "session_id": "a"])
        XCTAssertEqual(center.sessions.map(\.project), ["web"])
    }

    @MainActor
    func testDecidingAnswersAndClears() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "perch.tests.\(UUID().uuidString)"))
        let center = AgentCenter(prefs: Preferences(defaults: defaults), hud: HUDCenter())
        center.simulate(["hook_event_name": "PermissionRequest", "session_id": "a", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        let id = try XCTUnwrap(center.pendingApproval?.id)
        center.decide(id, allow: true)
        XCTAssertNil(center.pendingApproval)
        XCTAssertEqual(center.sessions.first?.state, .working)
    }
}

/// Runs the real `perch-hook` binary against the socket server.
final class AgentTransportTests: XCTestCase {
    private var helperURL: URL? {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("perch-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func socketPath() -> String {
        "/tmp/perch-test-\(UUID().uuidString.prefix(8)).sock"
    }

    private func runHelper(_ helper: URL, socket: String, input: [String: Any]) throws -> String {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["claude"]
        process.environment = ["PERCH_SOCKET": socket, "HOME": NSTemporaryDirectory(), "TERM_PROGRAM": "ghostty"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output, as: UTF8.self)
    }

    func testEventsArriveWithTerminalDetails() throws {
        let helper = try XCTUnwrap(helperURL, "build perch-hook first")
        let path = socketPath()
        let received = expectation(description: "event")
        let box = Box()
        let server = AgentSocketServer(path: path) { line, reply in
            box.message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            reply.send(nil)
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let output = try runHelper(helper, socket: path, input: ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/x"])
        wait(for: [received], timeout: 5)
        XCTAssertEqual(output, "")
        XCTAssertEqual(box.message?["source"] as? String, "claude")
        XCTAssertEqual((box.message?["payload"] as? [String: Any])?["session_id"] as? String, "s1")
        XCTAssertEqual((box.message?["env"] as? [String: String])?["TERM_PROGRAM"], "ghostty")
    }

    func testPermissionDecisionComesBack() throws {
        let helper = try XCTUnwrap(helperURL, "build perch-hook first")
        let path = socketPath()
        let decision = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        let server = AgentSocketServer(path: path) { _, reply in
            // Answer a moment later, like a click in the notch.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reply.send(Data(decision.utf8)) }
        }
        try server.start()
        defer { server.stop() }

        let output = try runHelper(helper, socket: path, input: ["hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "Bash"])
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), decision)
    }

    func testWithoutPerchTheHookStaysOutOfTheWay() throws {
        let helper = try XCTUnwrap(helperURL, "build perch-hook first")
        let start = Date()
        let output = try runHelper(helper, socket: socketPath(), input: ["hook_event_name": "PermissionRequest", "session_id": "s1"])
        XCTAssertEqual(output, "")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private final class Box: @unchecked Sendable {
        var message: [String: Any]?
    }
}
