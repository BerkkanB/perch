import SwiftUI
import Observation

/// Switches `pmset disablesleep`, which keeps the Mac running even with the lid closed.
///
/// Safety: an optional timer, plus guards that let the Mac sleep again when the battery runs low
/// or it gets too hot (for example closed in a bag).
@MainActor
@Observable
final class StayAwakeModule: PerchModule {
    let id = "stay-awake"
    let title = "Stay Awake"
    let caption = "Keeps your Mac running, even with the lid closed"
    let tint = Palette.stayAwake

    private(set) var isOn = false
    private(set) var isBusy = false
    private(set) var notice: ModuleNotice?

    var symbol: String { isOn ? "sun.max.fill" : "moon.zzz.fill" }

    var statusText: String {
        if isBusy { return "Applying…" }
        return isOn ? "Keeps running with the lid closed" : "Sleeps normally"
    }

    var timer: AutoOffTimer? { autoOff }
    var defaultShortcut: KeyCombo? { .stayAwakeDefault }
    var privilegedCommands: [[String]] {
        [PMSet.command(disableSleep: false), PMSet.command(disableSleep: true)]
    }

    @ObservationIgnored let autoOff: AutoOffTimer
    @ObservationIgnored private let context: ModuleContext
    @ObservationIgnored private var hasLoadedState = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastGuardAttempt: Date?

    init(context: ModuleContext) {
        self.context = context
        autoOff = AutoOffTimer(storageKey: "timer.stay-awake", defaults: context.defaults)
        autoOff.onExpire = { [weak self] in
            await self?.setOn(false, source: .automation(reason: "Timer ended"))
        }
    }

    func start() {
        context.power.onChange.append { [weak self] in self?.checkGuards() }
        // pmset has no change notification, and `pmset -g` takes a few milliseconds,
        // so polling picks up changes made in the Terminal.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refresh() async {
        guard !isBusy, let disabled = await PMSet.readSleepDisabled(), !isBusy else { return }
        isOn = disabled

        if !hasLoadedState {
            hasLoadedState = true
            // A timer saved by a previous run: re-arm it, or drop it if sleep was re-enabled meanwhile.
            if isOn { autoOff.resume() } else { autoOff.cancel() }
        } else if !isOn {
            autoOff.cancel()
        }
        checkGuards()
    }

    func setOn(_ on: Bool, source: ToggleSource) async {
        guard !isBusy else { return }

        if on, let reason = guardViolation() {
            notice = ModuleNotice(kind: .warning, message: "Didn't turn on: \(reason).")
            context.hud.show(HUDMessage(symbol: "exclamationmark.triangle.fill", title: "Can't stay awake", value: reason, tint: Palette.danger))
            autoOff.cancel()
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await context.access.run(
                PMSet.command(disableSleep: on),
                interactive: true,
                reason: on
                    ? "Perch wants to keep your Mac awake, even with the lid closed."
                    : "Perch wants to let your Mac sleep again."
            )
            isOn = on
            if !on { autoOff.cancel() }

            if case .automation(let reason) = source {
                notice = ModuleNotice(kind: .info, message: "\(on ? "Turned on" : "Sleep turned back on") · \(reason)")
            } else {
                notice = nil
            }
            if source.announces { announce(source: source) }
        } catch PrivilegeError.cancelled {
            if on { autoOff.cancel() }
        } catch {
            if on { autoOff.cancel() }
            notice = ModuleNotice(kind: .error, message: error.localizedDescription)
            if source.announces {
                context.hud.show(HUDMessage(symbol: "exclamationmark.triangle.fill", title: title, value: "Failed", tint: Palette.danger))
            }
        }
    }

    func prepareForQuit() async {
        // A running timer can't fire once Perch is gone, so honour it now.
        guard isOn, context.prefs.restoreSleepOnQuit || autoOff.isRunning else { return }
        await setOn(false, source: .automation(reason: "Perch quit"))
    }

    // MARK: Safety guards

    /// Why staying awake is unsafe right now, if it is.
    func guardViolation() -> String? {
        let prefs = context.prefs
        let power = context.power
        if prefs.batteryGuardEnabled, !power.isOnACPower, let level = power.batteryLevel,
           level <= prefs.batteryGuardThreshold {
            return "Battery at \(level)%"
        }
        if prefs.heatGuardEnabled {
            switch power.thermalState {
            case .critical:
                return "Mac too hot"
            case .serious where power.isLidClosed:
                return "Hot with lid closed"
            default:
                break
            }
        }
        return nil
    }

    private func checkGuards() {
        guard isOn, !isBusy, let reason = guardViolation() else { return }
        // Don't retry every poll if the user dismissed the password prompt.
        if let last = lastGuardAttempt, Date().timeIntervalSince(last) < 5 * 60 { return }
        lastGuardAttempt = Date()
        Task { await setOn(false, source: .automation(reason: reason)) }
    }

    // MARK: HUD

    private func announce(source: ToggleSource) {
        if case .automation(let reason) = source, !isOn {
            context.hud.show(HUDMessage(symbol: "moon.zzz.fill", title: "Sleep on", value: reason, tint: Palette.sleep))
            return
        }
        var value = isOn ? "On" : "Off"
        if isOn, let duration = autoOff.duration {
            value += " · \(DurationFormat.preset(duration))"
        }
        context.hud.show(HUDMessage(symbol: symbol, title: title, value: value, tint: isOn ? tint : Palette.sleep))
    }

    #if DEBUG
    /// For rendering previews without touching pmset.
    func setPreviewState(isOn: Bool) {
        self.isOn = isOn
    }
    #endif
}
