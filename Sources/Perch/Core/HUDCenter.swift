import SwiftUI
import Observation

/// A short message that slides out of the notch, e.g. "Stay Awake · On".
struct HUDMessage: Equatable, Identifiable {
    let id = UUID()
    var symbol: String
    var title: String
    var value: String
    var tint: Color
    /// A quieter word after the value, e.g. how long a turn took.
    var detail: String?
    /// An agent finished: shown with the animated tick, in wings sized to the name.
    var isDone = false

    /// "✓ auth-service ··· Done 4m" when an agent finishes. It stays up longer than a switch's
    /// HUD, since it arrives while you're looking at something else.
    static func done(_ title: String, after elapsed: TimeInterval? = nil) -> HUDMessage {
        HUDMessage(
            symbol: "checkmark.circle.fill", title: title, value: "Done", tint: Palette.good,
            detail: elapsed.map(DurationFormat.tight), isDone: true
        )
    }

    static let doneSeconds = 3.5
}

@MainActor
@Observable
final class HUDCenter {
    private(set) var current: HUDMessage?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Shows `message`, replacing any current one. 1.5 s is long enough to read a short HUD
    /// (Boring Notch uses the same); each new message restarts the clock.
    func show(_ message: HUDMessage, for seconds: Double = 1.5) {
        current = message
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}
