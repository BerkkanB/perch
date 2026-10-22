import Observation

/// Runs `apply` now and again every time an observable property it reads changes.
/// Lets AppKit objects (status item, windows) follow `@Observable` state the way SwiftUI views do.
@MainActor
func observeChanges(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observeChanges(apply) }
    }
}
