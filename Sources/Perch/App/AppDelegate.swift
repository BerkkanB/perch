import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var notch: NotchController?
    private var settings: SettingsWindowController?
    private var standby: StandByController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }

        let model = AppModel()
        let statusItem = StatusItemController(app: model)
        let notch = NotchController(app: model)
        let settings = SettingsWindowController(app: model)
        let standby = StandByController(app: model)

        model.openSettings = { [weak settings, weak notch, weak statusItem] in
            notch?.collapse()
            statusItem?.closePanel()
            settings?.show()
        }
        model.toggleMenu = { [weak statusItem] in statusItem?.togglePanel() }
        model.openStandBy = { [weak standby, weak notch, weak statusItem] in
            notch?.collapse()
            statusItem?.closePanel()
            standby?.show()
        }
        model.closeTransientUI = { [weak notch, weak statusItem] in
            notch?.collapse()
            statusItem?.closePanel()
        }

        model.start()
        notch.start()
        standby.start()

        self.model = model
        self.statusItem = statusItem
        self.notch = notch
        self.settings = settings
        self.standby = standby

        if !model.prefs.hasLaunchedBefore {
            model.prefs.hasLaunchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak statusItem] in
                statusItem?.showPanel()
            }
        }

        DemoMode.apply(arguments: CommandLine.arguments, model: model, notch: notch, statusItem: statusItem, settings: settings, standby: standby)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Only one Perch at a time: two would fight over the notch and the shortcuts.
    private func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return false }
        existing.activate()
        return true
    }
}
