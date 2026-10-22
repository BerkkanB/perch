import SwiftUI

/// Where a toggle came from. Changes the UI didn't show directly (shortcut, automation) get a notch HUD.
enum ToggleSource: Equatable {
    case ui
    case shortcut
    case menu
    case automation(reason: String)

    var announces: Bool {
        switch self {
        case .ui: false
        case .shortcut, .menu, .automation: true
        }
    }
}

/// A short note a module keeps about something that happened, e.g. "Turned off: battery at 14 %".
struct ModuleNotice: Equatable {
    enum Kind { case info, warning, error }

    var kind: Kind
    var message: String
    var date = Date()
}

/// One tool in Perch. The menu bar, notch, shortcuts and sudoers rule are all built from these.
///
/// To add a tool: write an `@Observable` class that conforms to this protocol and add it in
/// `AppModel.makeModules()`.
@MainActor
protocol PerchModule: AnyObject {
    /// Stable identifier, used as the key for preferences and shortcuts.
    var id: String { get }
    var title: String { get }
    /// One line describing what the tool does.
    var caption: String { get }
    var tint: Color { get }
    /// SF Symbol for the current state.
    var symbol: String { get }

    var isOn: Bool { get }
    var isBusy: Bool { get }
    /// Current status, e.g. "Sleeps normally".
    var statusText: String { get }
    var notice: ModuleNotice? { get }

    /// Non-nil if the tool can be switched on for a limited time.
    var timer: AutoOffTimer? { get }
    /// Root commands this tool runs. They are added to Perch's password-free sudoers rule.
    var privilegedCommands: [[String]] { get }
    var defaultShortcut: KeyCombo? { get }

    /// Starts any monitoring. Called once at launch.
    func start()
    /// Re-reads the real state from the system.
    func refresh() async
    func setOn(_ on: Bool, source: ToggleSource) async
    /// Called before the app quits.
    func prepareForQuit() async
}

extension PerchModule {
    var timer: AutoOffTimer? { nil }
    var privilegedCommands: [[String]] { [] }
    var defaultShortcut: KeyCombo? { nil }
    var notice: ModuleNotice? { nil }

    func start() {}
    func refresh() async {}
    func prepareForQuit() async {}

    func toggle(source: ToggleSource) async {
        await setOn(!isOn, source: source)
    }

    /// Turns the tool on for `duration`, or until turned off when `duration` is nil.
    func activate(for duration: TimeInterval?, source: ToggleSource) async {
        // Set the timer first so the HUD shown by `setOn` already knows the duration.
        if let duration {
            timer?.start(duration: duration)
        } else {
            timer?.cancel()
        }
        guard !isOn else { return }
        await setOn(true, source: source)
        if !isOn { timer?.cancel() }
    }
}
