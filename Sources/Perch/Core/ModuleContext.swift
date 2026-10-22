import Foundation

/// Shared services handed to every module.
@MainActor
struct ModuleContext {
    let prefs: Preferences
    let access: PrivilegedAccess
    let power: PowerMonitor
    let hud: HUDCenter
    /// Where modules keep their own small state, such as running timers.
    let defaults: UserDefaults
}
