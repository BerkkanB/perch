import AppKit

/// Brings an agent's terminal (or editor) to the front.
///
/// Phase 1 activates the app the agent runs in, found from the environment its hook ran with.
/// Jumping to the exact tab or tmux pane comes later.
@MainActor
enum TerminalJumper {
    static func jump(to terminal: TerminalInfo?) {
        guard let bundleID = terminal?.bundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
