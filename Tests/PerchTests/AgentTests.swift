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
    func testTwoWorkingSessionsKeepTheirOrderAndBothUpdate() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "perch.tests.\(UUID().uuidString)"))
        let center = AgentCenter(prefs: Preferences(defaults: defaults), hud: HUDCenter())
        center.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "one", "cwd": "/code/app", "prompt": "add login tests"])
        center.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "two", "cwd": "/code/app", "prompt": "fix flaky build"])
        for step in 0..<6 {
            let id = step.isMultiple(of: 2) ? "two" : "one"
            center.simulate(["hook_event_name": "PreToolUse", "session_id": id, "tool_name": "Read", "tool_input": ["file_path": "/f\(step).swift"]])
            XCTAssertEqual(center.sessions.map(\.id), ["claude:one", "claude:two"], "order must not follow the latest event")
        }
        XCTAssertEqual(center.sessions[0].glance?.text, "f5.swift")
        XCTAssertEqual(center.sessions[1].glance?.text, "f4.swift")

        let names = center.displayNames
        XCTAssertEqual(names["claude:one"], "app · add login tests")
        XCTAssertEqual(names["claude:two"], "app · fix flaky build")
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

    func testLongCommandsKeepEveryLine() {
        let command = "git add -A &&\n  git commit -m 'Release 2.0' &&\n  git push origin main"
        XCTAssertEqual(ToolDescription.detail(tool: "Bash", input: ["command": command + "\n"]), command)
        XCTAssertEqual(PendingApproval(tool: "Bash", input: ["command": "ls", "description": "List files"]).summary, "List files")
        XCTAssertEqual(ToolDescription.detail(tool: "Tool", input: [:]), "")
    }

    @MainActor
    func testPromptTagsDropTrailingPunctuation() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "perch.tests.\(UUID().uuidString)"))
        let center = AgentCenter(prefs: Preferences(defaults: defaults), hud: HUDCenter())
        center.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "one", "cwd": "/code/app", "prompt": "commit to main, then push"])
        center.simulate(["hook_event_name": "UserPromptSubmit", "session_id": "two", "cwd": "/code/app", "prompt": "fix it."])
        XCTAssertEqual(center.displayNames["claude:one"], "app · commit to main")
        XCTAssertEqual(center.displayNames["claude:two"], "app · fix it")
    }
}

final class AgentQuestionTests: XCTestCase {
    private let input: [String: Any] = ["questions": [
        [
            "question": "Which version bump should I use?",
            "header": "Version",
            "multiSelect": false,
            "options": [
                ["label": "Patch", "description": "Bug fixes only"],
                ["label": "Minor", "description": "New features, nothing breaks"],
            ],
        ],
        [
            "question": "Which sections should I include?",
            "header": "Sections",
            "multiSelect": true,
            "options": [
                ["label": "Introduction", "description": "Opening context"],
                ["label": "Usage", "description": ""],
                ["label": "Conclusion", "description": "Final summary"],
            ],
        ],
    ]]

    func testQuestionsAreReadFromTheToolInput() {
        let approval = PendingApproval(tool: "AskUserQuestion", input: input)
        XCTAssertEqual(approval.questions.map(\.header), ["Version", "Sections"])
        XCTAssertEqual(approval.questions[1].options.map(\.label), ["Introduction", "Usage", "Conclusion"])
        XCTAssertTrue(approval.questions[1].multiSelect)
        XCTAssertEqual(approval.detail, "", "questions show as options, not as raw JSON")
        XCTAssertTrue(PendingApproval(tool: "Bash", input: input).questions.isEmpty)
    }

    func testAnswersGoBackInClaudeCodesFormat() throws {
        let questions = AgentQuestion.questions(in: input)
        let selections: [String: Set<String>] = [
            "Which version bump should I use?": ["Minor"],
            "Which sections should I include?": ["Conclusion", "Introduction"],
        ]
        let updated = AgentCenter.answeredInput(input, questions: questions, selections: selections)
        let reply = try XCTUnwrap(AgentCenter.permissionReply(allow: true, updatedInput: updated))
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let hook = try XCTUnwrap(output["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual((updatedInput["questions"] as? [Any])?.count, 2, "the original questions go back too")
        XCTAssertEqual(updatedInput["answers"] as? [String: String], [
            "Which version bump should I use?": "Minor",
            // In Claude's order, not the order they were clicked.
            "Which sections should I include?": "Introduction, Conclusion",
        ])

        let skip = try XCTUnwrap(AgentCenter.permissionReply(allow: false, message: "Skipped"))
        let skipped = try XCTUnwrap(JSONSerialization.jsonObject(with: skip) as? [String: Any])
        let denial = try XCTUnwrap((skipped["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(denial["behavior"] as? String, "deny")
        XCTAssertEqual(denial["message"] as? String, "Skipped")
        XCTAssertNil(denial["updatedInput"])
    }

    @MainActor
    func testAnsweringSettlesTheSession() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "perch.tests.\(UUID().uuidString)"))
        let center = AgentCenter(prefs: Preferences(defaults: defaults), hud: HUDCenter())
        center.simulate(["hook_event_name": "PermissionRequest", "session_id": "a", "cwd": "/code/app", "tool_name": "AskUserQuestion", "tool_input": input])
        let session = try XCTUnwrap(center.pendingApproval)
        XCTAssertEqual(session.statusText, "Has 2 questions for you")
        XCTAssertEqual(session.badgeGlance.text, "asks you")

        center.answer(session.id, selections: ["Which version bump should I use?": ["Patch"]])
        XCTAssertNil(center.pendingApproval)
        XCTAssertEqual(center.sessions.first?.activity, "Answered")
    }

    func testTheCardGrowsWithItsQuestionsAndStopsAtALimit() {
        func height(_ input: [String: Any], tool: String = "AskUserQuestion") -> CGFloat {
            var session = AgentSession(id: "s", agent: .claude, cwd: "/a", state: .waiting, startedAt: .now, updatedAt: .now)
            session.approval = PendingApproval(tool: tool, input: input)
            return NotchModel.List.sessionCardHeight(for: session, listWidth: 476)
        }
        let one = height(["questions": [(input["questions"] as! [[String: Any]])[0]]])
        let two = height(input)
        let many = height(["questions": Array(repeating: (input["questions"] as! [[String: Any]])[1], count: 4)])
        XCTAssertGreaterThan(two, one)
        XCTAssertLessThanOrEqual(many, 82 + 8 + 360 + 8 + 28)

        let short = height(["command": "ls"], tool: "Bash")
        let long = height(["command": Array(repeating: "echo step", count: 8).joined(separator: "\n")], tool: "Bash")
        let huge = height(["command": Array(repeating: "echo step", count: 200).joined(separator: "\n")], tool: "Bash")
        XCTAssertGreaterThan(long, short + 80, "every line of a long command shows")
        XCTAssertLessThanOrEqual(huge, 82 + 8 + 20 + 15 + 6 + 220 + 8 + 28)
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
