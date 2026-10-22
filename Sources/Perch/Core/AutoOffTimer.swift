import Foundation
import Observation

/// Turns a module off after a chosen duration. The end time is saved, so a timer that ran out
/// while Perch was not running still takes effect on the next launch.
@MainActor
@Observable
final class AutoOffTimer {
    nonisolated static let presets: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]

    private(set) var endsAt: Date?
    private(set) var duration: TimeInterval?

    @ObservationIgnored var onExpire: (() async -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let defaults: UserDefaults

    init(storageKey: String, defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: storageKey),
           let end = saved["endsAt"] as? Date,
           let length = saved["duration"] as? TimeInterval {
            endsAt = end
            duration = length
        }
    }

    var isRunning: Bool { endsAt != nil }

    func remaining(at now: Date = .now) -> TimeInterval? {
        endsAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// 1 when just started, 0 when about to fire.
    func fractionRemaining(at now: Date = .now) -> Double {
        guard let remaining = remaining(at: now), let duration, duration > 0 else { return 0 }
        return min(1, remaining / duration)
    }

    func start(duration: TimeInterval) {
        self.duration = duration
        endsAt = Date().addingTimeInterval(duration)
        save()
        schedule()
    }

    func cancel() {
        task?.cancel()
        task = nil
        guard endsAt != nil else { return }
        endsAt = nil
        duration = nil
        save()
    }

    /// Re-arms a timer restored from disk. Fires right away if it ran out while Perch was closed.
    func resume() {
        schedule()
    }

    private func schedule() {
        task?.cancel()
        guard let endsAt else { return }
        task = Task { [weak self] in
            let delay = endsAt.timeIntervalSinceNow
            if delay > 0 {
                // ContinuousClock keeps counting while the Mac sleeps.
                try? await Task.sleep(for: .seconds(delay), clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        endsAt = nil
        duration = nil
        task = nil
        save()
        await onExpire?()
    }

    private func save() {
        if let endsAt, let duration {
            defaults.set(["endsAt": endsAt, "duration": duration], forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}

enum DurationFormat {
    /// "15m", "1h", "1h 30m"
    static func preset(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "42m left", "1h 05m left", "30s left"
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(total)s left" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m left" }
        return String(format: "%dh %02dm left", minutes / 60, minutes % 60)
    }

    /// Tight form for monospaced readouts: "45s", "27m", "2h", "4h1m"
    static func tight(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(rest)m"
    }

    /// Compact form for the menu bar and notch badge: "30s", "42m", "2h", "1h 5m"
    static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}
