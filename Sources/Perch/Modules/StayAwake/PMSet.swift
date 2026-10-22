import Foundation

/// Reads and builds `pmset` commands for the system-wide `disablesleep` flag.
enum PMSet {
    static let executable = "/usr/bin/pmset"

    /// `pmset -a disablesleep 1` keeps the Mac awake, even with the lid closed. Needs root.
    static func command(disableSleep: Bool) -> [String] {
        [executable, "-a", "disablesleep", disableSleep ? "1" : "0"]
    }

    /// Reads the flag with `pmset -g`, which needs no root. `nil` if pmset could not run.
    static func readSleepDisabled() async -> Bool? {
        let result = await Shell.run(executable, ["-g"])
        guard result.succeeded else { return nil }
        return parseSleepDisabled(result.stdout)
    }

    /// Finds `SleepDisabled  1` in `pmset -g` output. A missing line means sleep is allowed.
    static func parseSleepDisabled(_ output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] != "0"
            }
        }
        return false
    }
}
