import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import Observation

/// Battery, charger, thermal and lid state.
@MainActor
@Observable
final class PowerMonitor {
    /// Battery charge in percent, or `nil` on Macs without a battery.
    private(set) var batteryLevel: Int?
    private(set) var isCharging = false
    private(set) var isOnACPower = true
    /// macOS's estimate of the battery time left, while running on battery.
    private(set) var timeRemaining: TimeInterval?
    fileprivate(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// Called after any power or thermal change.
    @ObservationIgnored var onChange: [() -> Void] = []
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    var isLidClosed: Bool { Self.readClamshellClosed() }

    /// The lid is closed and macOS would normally be asleep. It keeps running with the lid closed
    /// only in clamshell mode, with an external display and a charger.
    var closedLidShouldSleep: Bool {
        Self.closedLidShouldSleep(lidClosed: isLidClosed, externalDisplay: Self.hasExternalDisplay(), onACPower: isOnACPower)
    }

    nonisolated static func closedLidShouldSleep(lidClosed: Bool, externalDisplay: Bool, onACPower: Bool) -> Bool {
        lidClosed && !(externalDisplay && onACPower)
    }

    func start() {
        update()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            // Delivered on the main run loop, where the source was added.
            MainActor.assumeIsolated { monitor.update() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func update() {
        thermalState = ProcessInfo.processInfo.thermalState
        readPowerSources()
        // Negative values mean "still calculating" or "on power adapter".
        let estimate = IOPSGetTimeRemainingEstimate()
        timeRemaining = estimate > 0 ? estimate : nil
        onChange.forEach { $0() }
    }

    private func readPowerSources() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            batteryLevel = nil
            return
        }

        var foundBattery = false
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            foundBattery = true
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            batteryLevel = Int((Double(current) / Double(maximum) * 100).rounded())
            isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            isOnACPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        }

        if !foundBattery {
            batteryLevel = nil
            isCharging = false
            isOnACPower = true
        }
    }

    private static func readClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool ?? false
    }

    private static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

#if DEBUG
extension PowerMonitor {
    /// For snapshots of the heat warning.
    func setPreviewThermalState(_ state: ProcessInfo.ThermalState) {
        thermalState = state
    }
}
#endif

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: "Unknown"
        }
    }
}
