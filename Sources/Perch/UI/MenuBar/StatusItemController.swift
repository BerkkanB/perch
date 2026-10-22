import AppKit
import SwiftUI

/// The menu bar icon. Click: panel. Right-click or ⌃-click: quick menu. ⌥-click: toggle Stay Awake.
@MainActor
final class StatusItemController: NSObject {
    private let app: AppModel
    private let item: NSStatusItem
    private let panel: MenuPanelController
    private var countdownTimer: Timer?

    init(app: AppModel) {
        self.app = app
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = MenuPanelController(app: app)
        super.init()

        panel.onVisibilityChange = { [weak self] shown in
            self?.item.button?.highlight(shown)
        }

        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.toolTip = "Perch"
        }

        observeChanges { [weak self] in self?.updateButton() }
    }

    // MARK: Panel

    func togglePanel() {
        panel.isShown ? closePanel() : showPanel()
    }

    func showPanel() {
        guard let button = item.button else { return }
        app.refreshAll()
        panel.show(below: button)
    }

    func closePanel() {
        panel.close()
    }

    /// The menu panel window, for snapshots.
    var panelWindow: NSWindow? { panel.window }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            Task { await app.primary.toggle(source: .menu) }
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        closePanel()
        let menu = NSMenu()

        for module in app.modules {
            let toggle = NSMenuItem(title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            toggle.target = self
            toggle.representedObject = module.id
            toggle.state = module.isOn ? .on : .off
            toggle.image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)
            if let combo = app.shortcut(for: module) {
                toggle.keyEquivalent = combo.keyName.count == 1 ? combo.keyName.lowercased() : ""
                toggle.keyEquivalentModifierMask = combo.modifierFlags
            }
            menu.addItem(toggle)

            if module.timer != nil {
                let durations = NSMenu()
                for preset in AutoOffTimer.presets {
                    let entry = NSMenuItem(title: DurationFormat.preset(preset), action: #selector(activateModule(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = TimedActivation(moduleID: module.id, duration: preset)
                    entry.state = module.isOn && module.timer?.duration == preset ? .on : .off
                    durations.addItem(entry)
                }
                let parent = NSMenuItem(title: "\(module.title) for", action: nil, keyEquivalent: "")
                parent.submenu = durations
                parent.indentationLevel = 1
                menu.addItem(parent)
            }
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private final class TimedActivation: NSObject {
        let moduleID: String
        let duration: TimeInterval
        init(moduleID: String, duration: TimeInterval) {
            self.moduleID = moduleID
            self.duration = duration
        }
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let module = app.modules.first(where: { $0.id == id }) else { return }
        Task { await module.toggle(source: .menu) }
    }

    @objc private func activateModule(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TimedActivation,
              let module = app.modules.first(where: { $0.id == request.moduleID }) else { return }
        Task { await module.activate(for: request.duration, source: .menu) }
    }

    @objc private func openSettings() {
        app.openSettings()
    }

    // MARK: Icon

    private func updateButton() {
        guard let button = item.button else { return }
        let primary = app.primary
        let lit = app.secondary.first { $0.isOn }
        let symbol = primary.isOn ? primary.symbol : (lit?.symbol ?? "moon.zzz")

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Perch")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityValue(primary.isOn ? "\(primary.title) on" : "\(primary.title) off")

        updateCountdown()
    }

    /// The soonest-ending timer of any module that is on.
    private var nextTimerEnd: Date? {
        app.modules
            .filter(\.isOn)
            .compactMap { $0.timer?.endsAt }
            .min()
    }

    private func updateCountdown() {
        guard let button = item.button else { return }
        guard app.prefs.menuBarShowsCountdown, let end = nextTimerEnd else {
            button.attributedTitle = NSAttributedString()
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }

        let remaining = max(0, end.timeIntervalSinceNow)
        button.attributedTitle = NSAttributedString(
            string: " " + DurationFormat.compact(remaining),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )

        // Tick every second in the last minute, otherwise every 10 s.
        let interval: TimeInterval = remaining <= 60 ? 1 : 10
        if countdownTimer?.timeInterval != interval {
            countdownTimer?.invalidate()
            countdownTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCountdown() }
            }
        }
    }
}
