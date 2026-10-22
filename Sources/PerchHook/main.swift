// perch-hook: the bridge between coding agents and Perch.
//
// Claude Code runs this from its hooks and status line:
//   perch-hook claude        a hook event as JSON on stdin
//   perch-hook statusline    the status line JSON on stdin; prints the status line
//
// It forwards the event, with a few terminal details from the environment, to Perch over a Unix
// socket that only this user can open. For a permission request it waits for the decision made
// in the notch and prints it for Claude Code. If Perch isn't running, or answers nothing, it
// prints nothing and exits 0, so the agent carries on exactly as without Perch.

import Darwin
import Foundation

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "claude"
let input = FileHandle.standardInput.readDataToEndOfFile()
let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let socketPath = ProcessInfo.processInfo.environment["PERCH_SOCKET"] ?? "\(home)/.perch/agent.sock"

/// Where the agent runs, so Perch can name the terminal and bring it forward.
func terminalDetails() -> [String: String] {
    let keys: Set<String> = [
        "TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "TMUX", "TMUX_PANE",
        "__CFBundleIdentifier", "VSCODE_PID",
    ]
    var details = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
    let tty = open("/dev/tty", O_RDONLY | O_NOCTTY)
    if tty >= 0 {
        if let name = ttyname(tty) { details["tty"] = String(cString: name) }
        close(tty)
    }
    return details
}

/// Sends one JSON line and returns the reply, or nil if Perch can't be reached.
func exchange(_ message: [String: Any], waitSeconds: Int) -> Data? {
    guard var line = try? JSONSerialization.data(withJSONObject: message) else { return nil }
    line.append(0x0A)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: waitSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard socketPath.utf8.count < capacity else { return nil }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, socketPath, capacity) }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == line.count else { return nil }
    guard waitSeconds > 0 else { return Data() }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        reply.append(buffer, count: count)
    }
    return reply
}

/// The status line Claude Code shows: the user's own, if Perch replaced one, else a short default.
func statusLine(from payload: [String: Any]?) -> String {
    let chain = "\(home)/.perch/statusline-chain"
    if let command = try? String(contentsOfFile: chain, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !command.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        if (try? process.run()) != nil {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    var parts: [String] = []
    if let model = (payload?["model"] as? [String: Any])?["display_name"] as? String {
        parts.append(model)
    }
    if let used = (payload?["context_window"] as? [String: Any])?["used_percentage"] as? Double {
        parts.append("ctx \(Int(used.rounded()))%")
    }
    let limits = payload?["rate_limits"] as? [String: Any]
    if let fiveHour = (limits?["five_hour"] as? [String: Any])?["used_percentage"] as? Double {
        parts.append("5h \(Int(fiveHour.rounded()))%")
    }
    return parts.joined(separator: " · ")
}

let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any]

switch mode {
case "statusline":
    _ = exchange(["v": 1, "kind": "statusline", "source": "claude", "payload": payload ?? [:]], waitSeconds: 0)
    print(statusLine(from: payload))

default:
    guard let payload else { exit(0) }
    let event = payload["hook_event_name"] as? String
    // A permission request waits for the notch, a little less than the hook's own timeout.
    let wait = event == "PermissionRequest" ? 590 : 3
    let message: [String: Any] = ["v": 1, "kind": "hook", "source": mode, "payload": payload, "env": terminalDetails()]
    if let reply = exchange(message, waitSeconds: wait), !reply.isEmpty {
        FileHandle.standardOutput.write(reply)
    }
}
exit(0)
