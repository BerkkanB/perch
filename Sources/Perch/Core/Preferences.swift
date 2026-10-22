import Foundation
import Observation

/// User settings, saved to `UserDefaults` as they change.
@MainActor
@Observable
final class Preferences {
    // Notch
    var notchEnabled: Bool { didSet { save(notchEnabled, .notchEnabled) } }
    var notchExpandsOnHover: Bool { didSet { save(notchExpandsOnHover, .notchExpandsOnHover) } }
    var notchShowsBadge: Bool { didSet { save(notchShowsBadge, .notchShowsBadge) } }
    var notchShowsHUD: Bool { didSet { save(notchShowsHUD, .notchShowsHUD) } }
    var notchShowsAgentActivity: Bool { didSet { save(notchShowsAgentActivity, .notchShowsAgentActivity) } }

    // Menu bar
    var menuBarShowsCountdown: Bool { didSet { save(menuBarShowsCountdown, .menuBarShowsCountdown) } }

    // Stay Awake safety
    var batteryGuardEnabled: Bool { didSet { save(batteryGuardEnabled, .batteryGuardEnabled) } }
    var batteryGuardThreshold: Int { didSet { save(batteryGuardThreshold, .batteryGuardThreshold) } }
    var heatGuardEnabled: Bool { didSet { save(heatGuardEnabled, .heatGuardEnabled) } }
    var restoreSleepOnQuit: Bool { didSet { save(restoreSleepOnQuit, .restoreSleepOnQuit) } }

    // StandBy
    /// Minutes of inactivity before StandBy opens by itself; 0 means never.
    var standbyIdleMinutes: Int { didSet { save(standbyIdleMinutes, .standbyIdleMinutes) } }
    var standbyRequiresAuth: Bool { didSet { save(standbyRequiresAuth, .standbyRequiresAuth) } }
    /// Minutes after which StandBy lets macOS's real lock take over; 0 means never.
    var standbyLockAfterMinutes: Int { didSet { save(standbyLockAfterMinutes, .standbyLockAfterMinutes) } }

    // Coding agents
    var agentApprovalsInNotch: Bool { didSet { save(agentApprovalsInNotch, .agentApprovalsInNotch) } }
    var agentShowsFinished: Bool { didSet { save(agentShowsFinished, .agentShowsFinished) } }

    // Bookkeeping
    var hasLaunchedBefore: Bool { didSet { save(hasLaunchedBefore, .hasLaunchedBefore) } }
    var installedRuleDigest: String? { didSet { save(installedRuleDigest, .installedRuleDigest) } }

    /// Shortcut overrides by name. A missing name means "use the default"; a stored `nil` combo
    /// means the user cleared it.
    private(set) var shortcuts: [String: StoredShortcut] {
        didSet { save(try? JSONEncoder().encode(shortcuts), .shortcuts) }
    }

    struct StoredShortcut: Codable, Equatable {
        var combo: KeyCombo?
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.notchEnabled.rawValue: true,
            Key.notchExpandsOnHover.rawValue: true,
            Key.notchShowsBadge.rawValue: true,
            Key.notchShowsHUD.rawValue: true,
            Key.notchShowsAgentActivity.rawValue: true,
            Key.menuBarShowsCountdown.rawValue: true,
            Key.batteryGuardEnabled.rawValue: true,
            Key.batteryGuardThreshold.rawValue: 15,
            Key.heatGuardEnabled.rawValue: true,
            Key.restoreSleepOnQuit.rawValue: false,
            Key.agentApprovalsInNotch.rawValue: true,
            Key.standbyIdleMinutes.rawValue: 0,
            Key.standbyRequiresAuth.rawValue: true,
            Key.standbyLockAfterMinutes.rawValue: 10,
            Key.agentShowsFinished.rawValue: true,
        ])

        notchEnabled = defaults.bool(forKey: Key.notchEnabled.rawValue)
        notchExpandsOnHover = defaults.bool(forKey: Key.notchExpandsOnHover.rawValue)
        notchShowsBadge = defaults.bool(forKey: Key.notchShowsBadge.rawValue)
        notchShowsHUD = defaults.bool(forKey: Key.notchShowsHUD.rawValue)
        notchShowsAgentActivity = defaults.bool(forKey: Key.notchShowsAgentActivity.rawValue)
        menuBarShowsCountdown = defaults.bool(forKey: Key.menuBarShowsCountdown.rawValue)
        batteryGuardEnabled = defaults.bool(forKey: Key.batteryGuardEnabled.rawValue)
        batteryGuardThreshold = defaults.integer(forKey: Key.batteryGuardThreshold.rawValue)
        heatGuardEnabled = defaults.bool(forKey: Key.heatGuardEnabled.rawValue)
        restoreSleepOnQuit = defaults.bool(forKey: Key.restoreSleepOnQuit.rawValue)
        agentApprovalsInNotch = defaults.bool(forKey: Key.agentApprovalsInNotch.rawValue)
        standbyIdleMinutes = defaults.integer(forKey: Key.standbyIdleMinutes.rawValue)
        standbyRequiresAuth = defaults.bool(forKey: Key.standbyRequiresAuth.rawValue)
        standbyLockAfterMinutes = defaults.integer(forKey: Key.standbyLockAfterMinutes.rawValue)
        agentShowsFinished = defaults.bool(forKey: Key.agentShowsFinished.rawValue)
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore.rawValue)
        installedRuleDigest = defaults.string(forKey: Key.installedRuleDigest.rawValue)
        shortcuts = defaults.data(forKey: Key.shortcuts.rawValue)
            .flatMap { try? JSONDecoder().decode([String: StoredShortcut].self, from: $0) } ?? [:]
    }

    func shortcut(for name: String, fallback: KeyCombo?) -> KeyCombo? {
        if let stored = shortcuts[name] { return stored.combo }
        return fallback
    }

    func setShortcut(_ combo: KeyCombo?, for name: String) {
        shortcuts[name] = StoredShortcut(combo: combo)
    }

    func resetShortcut(for name: String) {
        shortcuts[name] = nil
    }

    // MARK: Storage

    private enum Key: String {
        case notchEnabled, notchExpandsOnHover, notchShowsBadge, notchShowsHUD, notchShowsAgentActivity
        case menuBarShowsCountdown
        case batteryGuardEnabled, batteryGuardThreshold, heatGuardEnabled, restoreSleepOnQuit
        case agentApprovalsInNotch, agentShowsFinished
        case standbyIdleMinutes, standbyRequiresAuth, standbyLockAfterMinutes
        case hasLaunchedBefore, installedRuleDigest, shortcuts
    }

    private func save(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
