import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import LocalAuthentication
import SwiftUI

/// StandBy: a full-screen status screen (clock, agents, Stay Awake, battery), like StandBy on
/// iPhone. It opens from a shortcut, the menu, or after the Mac has been idle for a while.
///
/// While it shows, it keeps the display on, so the screen saver and macOS's own lock don't start.
/// It is a privacy screen, not a real lock: with "Ask for Touch ID" on (the default) closing it
/// needs Touch ID or the password, and app switching is blocked meanwhile, but force-quitting
/// Perch gets past it. So after a while (10 minutes by default) it hands over to the real lock by
/// turning the display off, and it closes itself whenever macOS locks or the Mac sleeps, so you
/// never have to unlock twice.
@MainActor
final class StandByController {
    private let app: AppModel
    private var windows: [StandByWindow] = []
    private var keyMonitor: Any?
    private var idleTimer: Timer?
    private var assertionID = IOPMAssertionID(0)
    private var isAuthenticating = false
    private var authContext: LAContext?
    private var handoverTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var isShown = false

    init(app: AppModel) {
        self.app = app
    }

    func start() {
        observeChanges { [weak self] in
            guard let self else { return }
            let minutes = app.prefs.standbyIdleMinutes
            DispatchQueue.main.async { self.watchIdle(minutes: minutes) }
        }

        // macOS's own lock (or sleep) replaces StandBy, so you only unlock once.
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }))
    }

    // MARK: Showing

    /// `onScreen: false` builds the windows far off screen without taking over the Mac, for snapshots.
    func show(onScreen: Bool = true) {
        guard !isShown else { return }
        isShown = true
        let requiresAuth = app.prefs.standbyRequiresAuth
        let main = Self.contentScreen

        for screen in NSScreen.screens {
            let window = StandByWindow(screen: screen)
            let view = StandByView(
                showsContent: screen == main,
                requiresAuth: requiresAuth,
                onDismiss: { [weak self] in self?.requestDismiss() }
            )
            .environment(app)
            window.contentView = NSHostingView(rootView: view)
            if !onScreen {
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            }
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }
        guard onScreen else {
            windows.forEach { $0.alphaValue = 1 }
            return
        }

        NSApp.activate()
        windows.first { $0.screen == main }?.makeKey()
        NSApp.presentationOptions = requiresAuth
            ? [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication, .disableAppleMenu]
            : [.hideDock, .hideMenuBar]
        NSCursor.setHiddenUntilMouseMoves(true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            windows.forEach { $0.animator().alphaValue = 1 }
        }

        // Keep the display (and so the screen saver and auto-lock) from kicking in underneath.
        IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Perch StandBy" as CFString,
            &assertionID
        )

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestDismiss() }
            return nil
        }

        scheduleHandover(after: app.prefs.standbyLockAfterMinutes)
    }

    /// After `minutes`, lets the display turn off so macOS's real lock takes over; StandBy closes
    /// when the lock notification arrives. If macOS doesn't ask for a password, StandBy stays.
    private func scheduleHandover(after minutes: Int) {
        handoverTask?.cancel()
        guard minutes > 0 else { return }
        handoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, self.isShown else { return }
            self.releaseDisplayAssertion()
            _ = await Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    private func releaseDisplayAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    /// A click or key press: close, after Touch ID or the password when that's turned on.
    func requestDismiss() {
        guard isShown, !isAuthenticating else { return }
        guard app.prefs.standbyRequiresAuth else {
            hide()
            return
        }

        isAuthenticating = true
        // The system's Touch ID / password prompt has to appear above StandBy.
        windows.forEach { $0.level = .normal }
        let context = LAContext()
        authContext = context
        context.localizedCancelTitle = "Keep StandBy"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "close StandBy") { success, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isShown else { return }
                self.isAuthenticating = false
                self.authContext = nil
                if success {
                    self.hide()
                } else {
                    self.windows.forEach { $0.level = .screenSaver }
                    self.windows.first { $0.screen == Self.contentScreen }?.makeKey()
                }
            }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        handoverTask?.cancel()
        authContext?.invalidate()
        authContext = nil
        isAuthenticating = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        releaseDisplayAssertion()
        NSApp.presentationOptions = []

        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated { closing.forEach { $0.orderOut(nil) } }
        }
    }

    /// For snapshots: the window that shows the content.
    var contentWindow: NSWindow? {
        windows.first { $0.screen == Self.contentScreen } ?? windows.first
    }

    /// The built-in display if it's on, else the main screen.
    private static var contentScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    // MARK: Opening when idle

    private func watchIdle(minutes: Int) {
        idleTimer?.invalidate()
        idleTimer = nil
        guard minutes > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isShown, !Self.isScreenLocked, !self.app.power.isLidClosed else { return }
                if Self.idleSeconds >= TimeInterval(minutes * 60) { self.show() }
            }
        }
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    private static var idleSeconds: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// A borderless black window covering one screen, above everything else.
final class StandByWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
