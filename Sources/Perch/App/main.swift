import AppKit

// Build-time helpers: `Perch --render-icon <dir>` writes the app icon set,
// `Perch --render-previews <dir>` writes PNGs of the UI for review.
if let command = Renderer.Command(arguments: CommandLine.arguments) {
    _ = NSApplication.shared
    let succeeded = MainActor.assumeIsolated { Renderer.run(command) }
    exit(succeeded ? 0 : 1)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
    // `run()` only returns at exit; this keeps the delegate (held weakly by NSApp) alive until then.
    withExtendedLifetime(delegate) {}
}
