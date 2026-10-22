import AppKit
import CryptoKit
import Observation

enum PrivilegeError: LocalizedError, Equatable {
    case cancelled
    case needsSetup
    case invalidUserName(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled."
        case .needsSetup: "Perch needs a one-time approval before it can do this without asking for your password."
        case .invalidUserName(let name): "Can't write a sudoers rule for the user name “\(name)”."
        case .failed(let message): message.isEmpty ? "The command failed." : message
        }
    }
}

/// Runs root commands for modules.
///
/// After a one-time approval Perch writes `/etc/sudoers.d/perch`, which lets the current user run
/// only the exact commands the modules declare (for example `/usr/bin/pmset -a disablesleep 1`)
/// with `sudo -n`, without a password. Until then every privileged call falls back to the
/// standard macOS admin prompt.
@MainActor
@Observable
final class PrivilegedAccess {
    nonisolated static let rulePath = "/private/etc/sudoers.d/perch"

    /// The rule file exists.
    private(set) var isInstalled = false
    /// The installed rule covers every command the modules need right now.
    private(set) var isCurrent = false

    /// Root commands the registered modules need, one argument vector each.
    var commands: [[String]] = [] {
        didSet { refresh() }
    }

    @ObservationIgnored private let prefs: Preferences

    init(prefs: Preferences) {
        self.prefs = prefs
        refresh()
    }

    var needsAttention: Bool { !commands.isEmpty && !isCurrent }

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: Self.rulePath)
        let expected = (try? Self.ruleText(user: NSUserName(), commands: commands)).map(Self.digest)
        isCurrent = isInstalled && expected != nil && prefs.installedRuleDigest == expected
    }

    /// The rule as it will be written, for showing in Settings.
    var previewRule: String {
        (try? Self.ruleText(user: NSUserName(), commands: commands)) ?? ""
    }

    // MARK: Running commands

    /// Runs `command` as root. Tries `sudo -n` first; if that needs a password and `interactive`
    /// is true, shows the admin prompt instead.
    func run(_ command: [String], interactive: Bool, reason: String) async throws {
        let result = await Shell.run("/usr/bin/sudo", ["-n"] + command)
        if result.succeeded { return }

        let refusedBySudo = result.stderr.contains("password is required")
            || result.stderr.contains("may not run")
            || result.stderr.contains("not allowed")
            || result.stderr.contains("not in the sudoers")
        guard refusedBySudo else {
            throw PrivilegeError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if isCurrent {
            // The rule was removed or edited outside Perch.
            refresh()
        }
        guard interactive else { throw PrivilegeError.needsSetup }
        try runWithAdminPrompt(command.map(Self.shellQuote).joined(separator: " "), prompt: reason)
    }

    // MARK: Installing the rule

    func installRule() throws {
        let text = try Self.ruleText(user: NSUserName(), commands: commands)
        try runWithAdminPrompt(
            Self.installScript(ruleText: text),
            prompt: "Perch wants to switch sleep settings without asking for your password every time."
        )
        prefs.installedRuleDigest = Self.digest(text)
        refresh()
    }

    func removeRule() throws {
        try runWithAdminPrompt(
            "/bin/rm -f \(Self.rulePath)",
            prompt: "Perch wants to remove its password-free permission."
        )
        prefs.installedRuleDigest = nil
        refresh()
    }

    // MARK: Building blocks (static so they can be tested)

    nonisolated static func ruleText(user: String, commands: [[String]]) throws -> String {
        guard user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            throw PrivilegeError.invalidUserName(user)
        }
        let specs = commands.map { $0.map(escapeSudoersArgument).joined(separator: " ") }
        return [
            "# Managed by Perch. Lets \(user) run these exact commands without a password.",
            "# Remove it from Perch Settings, or run: sudo rm /etc/sudoers.d/perch",
            "\(user) ALL=(root) NOPASSWD: \(specs.joined(separator: ", "))",
        ].joined(separator: "\n")
    }

    /// Shell script (run as root) that writes the rule, checks it with `visudo`, and only then
    /// moves it into place. sudo ignores files whose names contain a dot, so the `.tmp` file is inert.
    nonisolated static func installScript(ruleText: String) -> String {
        let temp = rulePath + ".tmp"
        let lines = ruleText.split(separator: "\n", omittingEmptySubsequences: false).map { shellQuote(String($0)) }
        let steps = [
            "/bin/mkdir -p /private/etc/sudoers.d",
            "/usr/bin/printf '%s\\n' \(lines.joined(separator: " ")) > \(temp)",
            "/usr/sbin/chown root:wheel \(temp)",
            "/bin/chmod 0440 \(temp)",
            "/usr/sbin/visudo -cqf \(temp)",
            "/bin/mv -f \(temp) \(rulePath)",
        ]
        return steps.joined(separator: " && ") + " || { /bin/rm -f \(temp); exit 1; }"
    }

    nonisolated static func escapeSudoersArgument(_ argument: String) -> String {
        var escaped = ""
        for character in argument {
            if "\\,:=".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    nonisolated static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Admin prompt

    private func runWithAdminPrompt(_ shellCommand: String, prompt: String) throws {
        func appleScriptString(_ value: String) -> String {
            "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(appleScriptString(shellCommand)) with prompt \(appleScriptString(prompt)) with administrator privileges"

        NSApp.activate()
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }

        if (error[NSAppleScript.errorNumber] as? Int) == -128 {
            throw PrivilegeError.cancelled
        }
        throw PrivilegeError.failed(error[NSAppleScript.errorMessage] as? String ?? "")
    }
}
