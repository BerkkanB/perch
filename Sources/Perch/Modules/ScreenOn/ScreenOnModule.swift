import IOKit.pwr_mgt
import SwiftUI
import Observation

/// Holds a power assertion that keeps the display from dimming or sleeping, like `caffeinate -d`.
/// Needs no root, and macOS drops the assertion by itself if Perch quits.
@MainActor
@Observable
final class ScreenOnModule: PerchModule {
    let id = "screen-on"
    let title = "Screen On"
    let caption = "Keeps the display from sleeping"
    let tint = Palette.screenOn

    private(set) var isOn = false
    let isBusy = false
    private(set) var notice: ModuleNotice?

    var symbol: String { isOn ? "lightbulb.max.fill" : "lightbulb" }
    var statusText: String { isOn ? "Display stays on" : "Display sleeps normally" }
    var timer: AutoOffTimer? { autoOff }

    @ObservationIgnored let autoOff: AutoOffTimer
    @ObservationIgnored private let context: ModuleContext
    @ObservationIgnored private var assertionID = IOPMAssertionID(0)

    init(context: ModuleContext) {
        self.context = context
        autoOff = AutoOffTimer(storageKey: "timer.screen-on", defaults: context.defaults)
        // The assertion never outlives the process, so a saved timer has nothing to resume.
        autoOff.cancel()
        autoOff.onExpire = { [weak self] in
            await self?.setOn(false, source: .automation(reason: "Timer ended"))
        }
    }

    func setOn(_ on: Bool, source: ToggleSource) async {
        if on {
            guard !isOn else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Perch: Screen On" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                notice = ModuleNotice(kind: .error, message: "macOS refused the display assertion (\(result)).")
                autoOff.cancel()
                return
            }
            assertionID = id
            isOn = true
        } else {
            autoOff.cancel()
            guard isOn else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isOn = false
        }

        if case .automation(let reason) = source {
            notice = ModuleNotice(kind: .info, message: "Turned off · \(reason)")
        } else {
            notice = nil
        }
        if source.announces {
            var value = isOn ? "On" : "Off"
            if isOn, let duration = autoOff.duration { value += " · \(DurationFormat.preset(duration))" }
            context.hud.show(HUDMessage(symbol: symbol, title: title, value: value, tint: tint))
        }
    }

    func prepareForQuit() async {
        await setOn(false, source: .ui)
    }
}
