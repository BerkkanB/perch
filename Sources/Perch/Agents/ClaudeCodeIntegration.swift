import Foundation
import Observation

/// Connects Claude Code to Perch by adding hooks and a status line to `~/.claude/settings.json`.
///
/// Every entry Perch adds runs `~/.perch/bin/perch-hook`, which is how Perch finds (and removes)
/// its own entries; everything else in the file is left as it was. The file is backed up to
/// `~/.perch/backups` before each change. A status line the user already had keeps working:
/// Perch saves its command and `perch-hook statusline` runs it.
@MainActor
@Observable
final class ClaudeCodeIntegration {
    private(set) var isConnected = false
    private(set) var lastError: String?

    nonisolated static let perchDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".perch")
    nonisolated static let helperURL = perchDirectory.appendingPathComponent("bin/perch-hook")
    nonisolated static let statusLineChainURL = perchDirectory.appendingPathComponent("statusline-chain")
    nonisolated static let settingsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")

    /// Events Perch listens to. Tool events take a matcher; the rest don't.
    nonisolated static let toolEvents = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
    nonisolated static let otherEvents = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"]

    func refresh() {
        let settings = (try? Self.readSettings()) ?? [:]
        isConnected = Self.containsPerch(settings)
    }

    func connect() {
        do {
            try Self.ensurePerchDirectory()
            try installHelper()
            var settings = try Self.readSettings()
            try backUp()

            if let existing = Self.statusLineCommand(in: settings), !existing.contains("perch-hook") {
                try existing.write(to: Self.statusLineChainURL, atomically: true, encoding: .utf8)
            }
            settings = Self.addingPerch(to: settings, helperPath: Self.helperURL.path)
            try Self.writeSettings(settings)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func disconnect() {
        do {
            var settings = try Self.readSettings()
            try backUp()
            let chained = try? String(contentsOf: Self.statusLineChainURL, encoding: .utf8)
            settings = Self.removingPerch(from: settings, restoringStatusLine: chained?.trimmingCharacters(in: .whitespacesAndNewlines))
            try Self.writeSettings(settings)
            try? FileManager.default.removeItem(at: Self.statusLineChainURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Keeps the installed helper in step with the one in this build of Perch.
    func updateInstalledHelperIfNeeded() {
        guard isConnected, let bundled = Self.bundledHelperURL else { return }
        let installed = Self.helperURL
        let same = FileManager.default.contentsEqual(atPath: bundled.path, andPath: installed.path)
        if !same { try? installHelper() }
    }

    // MARK: Settings edits (pure, so they can be tested)

    nonisolated static func command(helperPath: String, _ argument: String) -> String {
        "\(PrivilegedAccess.shellQuote(helperPath)) \(argument)"
    }

    nonisolated static func addingPerch(to settings: [String: Any], helperPath: String) -> [String: Any] {
        var settings = removingPerch(from: settings, restoringStatusLine: nil, keepStatusLine: true)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in toolEvents + otherEvents {
            var handler: [String: Any] = ["type": "command", "command": command(helperPath: helperPath, "claude")]
            // A permission request waits for the notch; everything else must be quick.
            handler["timeout"] = event == "PermissionRequest" ? 600 : 5
            var group: [String: Any] = ["hooks": [handler]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        settings["statusLine"] = ["type": "command", "command": command(helperPath: helperPath, "statusline")]
        return settings
    }

    nonisolated static func removingPerch(
        from settings: [String: Any],
        restoringStatusLine previous: String?,
        keepStatusLine: Bool = false
    ) -> [String: Any] {
        var settings = settings
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = groups.compactMap { group in
                    var group = group
                    let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { !isPerch($0) }
                    guard !handlers.isEmpty else { return nil }
                    group["hooks"] = handlers
                    return group
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if !keepStatusLine, let statusLine = settings["statusLine"] as? [String: Any], isPerch(statusLine) {
            if let previous, !previous.isEmpty {
                settings["statusLine"] = ["type": "command", "command": previous]
            } else {
                settings["statusLine"] = nil
            }
        }
        return settings
    }

    nonisolated static func containsPerch(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isPerch)
            }
        }
    }

    nonisolated static func statusLineCommand(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    nonisolated private static func isPerch(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains("perch-hook") == true
    }

    // MARK: Files

    nonisolated static func ensurePerchDirectory() throws {
        let manager = FileManager.default
        for directory in [perchDirectory, perchDirectory.appendingPathComponent("bin"), perchDirectory.appendingPathComponent("backups")] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: perchDirectory.path)
    }

    /// The helper inside the app bundle (or next to a debug build).
    nonisolated static var bundledHelperURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/perch-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("perch-hook"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func installHelper() throws {
        guard let bundled = Self.bundledHelperURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "perch-hook is missing from this build of Perch."])
        }
        let manager = FileManager.default
        let target = Self.helperURL
        let temporary = target.appendingPathExtension("new")
        try? manager.removeItem(at: temporary)
        try manager.copyItem(at: bundled, to: temporary)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        _ = try manager.replaceItemAt(target, withItemAt: temporary)
    }

    private func backUp() throws {
        guard FileManager.default.fileExists(atPath: Self.settingsURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = Self.perchDirectory.appendingPathComponent("backups/claude-settings-\(stamp).json")
        try FileManager.default.copyItem(at: Self.settingsURL, to: backup)
    }

    nonisolated static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object."])
        }
        return settings
    }

    nonisolated private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
