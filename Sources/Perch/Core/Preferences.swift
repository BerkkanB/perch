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

    // Menu bar
    var menuBarShowsCountdown: Bool { didSet { save(menuBarShowsCountdown, .menuBarShowsCountdown) } }

    // Stay Awake safety
    var batteryGuardEnabled: Bool { didSet { save(batteryGuardEnabled, .batteryGuardEnabled) } }
    var batteryGuardThreshold: Int { didSet { save(batteryGuardThreshold, .batteryGuardThreshold) } }
    var heatGuardEnabled: Bool { didSet { save(heatGuardEnabled, .heatGuardEnabled) } }
    var restoreSleepOnQuit: Bool { didSet { save(restoreSleepOnQuit, .restoreSleepOnQuit) } }

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
            Key.menuBarShowsCountdown.rawValue: true,
            Key.batteryGuardEnabled.rawValue: true,
            Key.batteryGuardThreshold.rawValue: 15,
            Key.heatGuardEnabled.rawValue: true,
            Key.restoreSleepOnQuit.rawValue: false,
        ])

        notchEnabled = defaults.bool(forKey: Key.notchEnabled.rawValue)
        notchExpandsOnHover = defaults.bool(forKey: Key.notchExpandsOnHover.rawValue)
        notchShowsBadge = defaults.bool(forKey: Key.notchShowsBadge.rawValue)
        notchShowsHUD = defaults.bool(forKey: Key.notchShowsHUD.rawValue)
        menuBarShowsCountdown = defaults.bool(forKey: Key.menuBarShowsCountdown.rawValue)
        batteryGuardEnabled = defaults.bool(forKey: Key.batteryGuardEnabled.rawValue)
        batteryGuardThreshold = defaults.integer(forKey: Key.batteryGuardThreshold.rawValue)
        heatGuardEnabled = defaults.bool(forKey: Key.heatGuardEnabled.rawValue)
        restoreSleepOnQuit = defaults.bool(forKey: Key.restoreSleepOnQuit.rawValue)
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
        case notchEnabled, notchExpandsOnHover, notchShowsBadge, notchShowsHUD
        case menuBarShowsCountdown
        case batteryGuardEnabled, batteryGuardThreshold, heatGuardEnabled, restoreSleepOnQuit
        case hasLaunchedBefore, installedRuleDigest, shortcuts
    }

    private func save(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
