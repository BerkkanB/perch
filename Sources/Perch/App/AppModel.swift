import AppKit
import Observation

/// Owns the shared services and the modules; the UI layers read everything from here.
@MainActor
@Observable
final class AppModel {
    static let menuShortcutName = "open-menu"

    let prefs: Preferences
    let power = PowerMonitor()
    let hud = HUDCenter()
    let access: PrivilegedAccess
    let loginItem = LoginItem()
    let hotKeys = HotKeyCenter.shared
    let agents: AgentCenter

    let stayAwake: StayAwakeModule
    let modules: [any PerchModule]

    // Hooks the AppDelegate fills in, so views can reach windows they don't own.
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var toggleMenu: () -> Void = {}
    @ObservationIgnored var closeTransientUI: () -> Void = {}

    init(defaults: UserDefaults = .standard) {
        prefs = Preferences(defaults: defaults)
        access = PrivilegedAccess(prefs: prefs)
        agents = AgentCenter(prefs: prefs, hud: hud)

        let context = ModuleContext(prefs: prefs, access: access, power: power, hud: hud, defaults: defaults)
        stayAwake = StayAwakeModule(context: context)
        modules = Self.makeModules(stayAwake: stayAwake, context: context)
        access.commands = modules.flatMap(\.privilegedCommands)
    }

    /// The registry. Add new tools here; the first one gets the large controls in the notch.
    private static func makeModules(stayAwake: StayAwakeModule, context: ModuleContext) -> [any PerchModule] {
        [
            stayAwake,
            ScreenOnModule(context: context),
        ]
    }

    var primary: any PerchModule { modules[0] }
    var secondary: [any PerchModule] { Array(modules.dropFirst()) }

    func start() {
        power.start()
        modules.forEach { $0.start() }
        registerShortcuts()
        // Snapshot runs of a debug build must not take the agent socket from the running app.
        if !CommandLine.arguments.contains("--snapshot") {
            agents.start()
        }
    }

    func refreshAll() {
        access.refresh()
        loginItem.refresh()
        for module in modules {
            Task { await module.refresh() }
        }
    }

    // MARK: Shortcuts

    func shortcut(for module: any PerchModule) -> KeyCombo? {
        prefs.shortcut(for: module.id, fallback: module.defaultShortcut)
    }

    var menuShortcut: KeyCombo? {
        prefs.shortcut(for: Self.menuShortcutName, fallback: nil)
    }

    func registerShortcuts() {
        for module in modules {
            hotKeys.set(module.id, combo: shortcut(for: module)) { [weak module] in
                guard let module else { return }
                Task { await module.toggle(source: .shortcut) }
            }
        }
        hotKeys.set(Self.menuShortcutName, combo: menuShortcut) { [weak self] in
            self?.toggleMenu()
        }
    }

    // MARK: Quitting

    func prepareForQuit() async {
        agents.stop()
        for module in modules {
            await module.prepareForQuit()
        }
    }
}
