import AppKit
import SwiftUI

/// Runs the notch: two panels and the staged open/close animation.
///
/// - The **canvas** panel draws the notch. It has a fixed size and position centred on the
///   camera, so the shape always grows out of the centre and shrinks back into it. It lets
///   clicks through except while open.
/// - The **hot zone** panel is an invisible strip over the notch that notices the pointer and
///   clicks, so the canvas never blocks the menu bar.
@MainActor
final class NotchController {
    let model: NotchModel

    private let app: AppModel
    private var canvas: NotchPanel?
    private var canvasView: NotchCanvasView?
    private var hotZone: NotchPanel?
    private var shownPhase: NotchModel.Phase
    private var transition: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var exitWatcher: Timer?
    private var screenObserver: NSObjectProtocol?

    init(app: AppModel) {
        self.app = app
        let geometry = Self.targetScreen().map(NotchGeometry.init(screen:))
            ?? NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 0, notchHeight: 24)
        model = NotchModel(app: app, geometry: geometry)
        shownPhase = model.targetPhase
    }

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }

        observeChanges { [weak self] in
            guard let self else { return }
            _ = app.prefs.notchEnabled
            // Outside the tracking closure, so only the setting is observed here.
            DispatchQueue.main.async { self.rebuild() }
        }
        observeChanges { [weak self] in
            guard let self else { return }
            let target = model.targetPhase
            let badgeWidth = model.bodySize(for: .badge).width
            let openHeight = model.bodySize(for: .expanded).height
            DispatchQueue.main.async {
                if target == .badge, target == self.shownPhase, badgeWidth != self.shownBadgeWidth {
                    self.resizeBadge(from: self.shownBadgeWidth, to: badgeWidth)
                }
                if openHeight != self.shownOpenHeight {
                    self.resizeOpen(from: self.shownOpenHeight, to: openHeight)
                }
                self.shownBadgeWidth = badgeWidth
                self.shownOpenHeight = openHeight
                self.show(target)
            }
        }
    }

    private var shownBadgeWidth: CGFloat = 0
    private var shownOpenHeight: CGFloat = 0
    private var canvasShrinkTask: Task<Void, Never>?

    /// Sessions came or went, or an approval appeared: the open list changed height. The panel
    /// grows at once and shrinks after the shape has, and an open notch springs to the new height.
    private func resizeOpen(from old: CGFloat, to new: CGFloat) {
        guard let canvas else { return }
        canvasShrinkTask?.cancel()
        let target = frame(for: model.canvasSize)
        if target.height >= canvas.frame.height {
            canvas.setFrame(target, display: true)
        } else {
            canvasShrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, let canvas = self.canvas else { return }
                canvas.setFrame(self.frame(for: self.model.canvasSize), display: true)
            }
        }
        if shownPhase == .expanded, old > 0 {
            canvasView?.setShape(height: new, spring: new > old ? Motion.drop : Motion.lift)
        }
    }

    /// A timer started or stopped, or the heat level changed, while the badge is showing:
    /// widen or narrow both sides together.
    private func resizeBadge(from old: CGFloat, to new: CGFloat) {
        canvasView?.setShape(width: new, spring: new > old ? Motion.wingsOut : Motion.wingsIn)
        updateMouseHandling(for: .badge)
    }

    /// The panel that draws the notch, for snapshots.
    var canvasWindow: NSWindow? { canvas }

    func expand() {
        guard canvas != nil, model.geometry.hasNotch, !model.isExpanded else { return }
        app.refreshAll()
        model.isExpanded = true
    }

    func collapse() {
        hoverTask?.cancel()
        model.isExpanded = false
    }

    // MARK: Animation

    /// Animates from what is on screen now to `target`. A new target cancels the steps still
    /// pending, and every spring starts from the current on-screen value, so reversing midway
    /// looks continuous.
    private func show(_ target: NotchModel.Phase) {
        guard target != shownPhase else { return }
        shownPhase = target
        transition?.cancel()
        updateMouseHandling(for: target)

        transition = Task { [weak self] in
            await self?.animate(to: target)
        }
    }

    private func animate(to target: NotchModel.Phase) async {
        guard let shape = canvasView else { return }
        let size = model.bodySize(for: target)
        let radii = model.radii(for: target)
        let lineHeight = model.geometry.notchHeight
        let lineRadii = model.radii(for: .badge)

        func pause(_ milliseconds: Int) async -> Bool {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            return !Task.isCancelled
        }
        func showContent(_ phase: NotchModel.Phase?, _ animation: Animation) {
            withAnimation(animation) { model.contentPhase = phase }
        }

        if Motion.reduceMotion {
            // Cross-fades only: content out, resize at once, content back in.
            showContent(nil, Motion.reduced)
            guard await pause(200) else { return }
            shape.setShadow(visible: false)
            shape.setShape(width: size.width, height: size.height, topRadius: radii.top, bottomRadius: radii.bottom, spring: nil)
            if target == .expanded { shape.setShadow(visible: true) }
            guard target != .idle else { return }
            showContent(target, Motion.reduced)
            return
        }

        if target == .expanded {
            // 1. Stretch sideways from the camera, as a line.
            showContent(nil, Motion.contentOut)
            shape.setShape(
                width: size.width, height: lineHeight,
                topRadius: lineRadii.top, bottomRadius: lineRadii.bottom,
                spring: Motion.stretch
            )
            guard await pause(90) else { return }

            // 2. Drop down while the stretch is still settling.
            shape.setShape(height: size.height, topRadius: radii.top, bottomRadius: radii.bottom, spring: Motion.drop)
            guard await pause(120) else { return }

            // 3. The list fades in, then the shadow.
            showContent(.expanded, Motion.contentIn)
            guard await pause(200) else { return }
            shape.setShadow(visible: true)
            return
        }

        showContent(nil, Motion.contentOut)
        if shape.bodyHeight > lineHeight + 0.5 {
            // Closing: 1. once the list is fading, lift back up to a line.
            shape.setShadow(visible: false)
            guard await pause(60) else { return }
            shape.setShape(height: lineHeight, topRadius: lineRadii.top, bottomRadius: lineRadii.bottom, spring: Motion.lift)
            guard await pause(130) else { return }

            // 2. Pull into the centre.
            shape.setShape(
                width: size.width, height: size.height,
                topRadius: radii.top, bottomRadius: radii.bottom,
                spring: Motion.retract
            )
            guard target != .idle, await pause(150) else { return }
        } else {
            // Between the small states only the wings move.
            let growing = size.width > shape.bodyWidth
            shape.setShape(
                width: size.width, height: size.height,
                topRadius: radii.top, bottomRadius: radii.bottom,
                spring: growing ? Motion.wingsOut : Motion.wingsIn
            )
            guard target != .idle, await pause(growing ? 100 : 60) else { return }
        }
        showContent(target, Motion.contentIn)
    }

    /// Jumps straight to `phase`, without animation.
    private func snap(to phase: NotchModel.Phase) {
        let size = model.bodySize(for: phase)
        let radii = model.radii(for: phase)
        canvasView?.layoutSubtreeIfNeeded()
        canvasView?.setShape(
            width: size.width, height: size.height,
            topRadius: radii.top, bottomRadius: radii.bottom,
            spring: nil
        )
        canvasView?.setShadow(visible: phase == .expanded)
        model.contentPhase = phase
    }

    // MARK: Panels

    /// The built-in display if it has a notch (it disappears in clamshell mode), else the main screen.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func rebuild() {
        guard app.prefs.notchEnabled, let screen = Self.targetScreen() else {
            canvas?.orderOut(nil)
            hotZone?.orderOut(nil)
            canvas = nil
            canvasView = nil
            hotZone = nil
            model.isExpanded = false
            return
        }

        transition?.cancel()
        model.geometry = NotchGeometry(screen: screen)
        shownPhase = model.targetPhase

        if canvas == nil { canvas = makeCanvas() }
        if hotZone == nil { hotZone = makeHotZone() }
        canvas?.setFrame(frame(for: model.canvasSize), display: true)
        snap(to: shownPhase)
        updateMouseHandling(for: shownPhase)
        hotZone?.orderFrontRegardless()
        canvas?.orderFrontRegardless()
    }

    private func makeCanvas() -> NotchPanel {
        let panel = NotchPanel()
        let root = NotchRootView(model: model).environment(app)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        let view = NotchCanvasView(content: hosting)
        panel.contentView = view
        canvasView = view
        return panel
    }

    private func makeHotZone() -> NotchPanel {
        let panel = NotchPanel()
        // Explicitly accepting mouse events makes the fully transparent panel clickable.
        panel.ignoresMouseEvents = false
        let view = NotchHotZoneView(frame: .zero)
        view.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        view.onClick = { [weak self] in self?.expand() }
        panel.contentView = view
        return panel
    }

    private func updateMouseHandling(for phase: NotchModel.Phase) {
        let isOpen = phase == .expanded
        canvas?.ignoresMouseEvents = !isOpen

        if isOpen {
            startWatchingForExit()
        } else {
            stopWatchingForExit()
        }

        guard let hotZone else { return }
        if model.geometry.hasNotch {
            // The camera plus any wings beside it; never below the menu bar.
            let closed = phase == .expanded ? NotchModel.Phase.idle : phase
            let width = max(model.bodySize(for: closed).width, model.geometry.notchWidth)
            hotZone.setFrame(frame(for: CGSize(width: width, height: model.geometry.notchHeight)), display: false)
            hotZone.orderFrontRegardless()
        } else {
            hotZone.orderOut(nil)
        }
    }

    private func frame(for size: CGSize) -> CGRect {
        let geometry = model.geometry
        return CGRect(
            x: geometry.midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Hover

    private func hoverChanged(_ inside: Bool) {
        hoverTask?.cancel()
        guard !model.isExpanded, model.geometry.hasNotch else { return }
        swell(inside)
        guard inside, app.prefs.notchExpandsOnHover else { return }
        // Opening waits for the hover-intent delay, so sweeping past the notch doesn't open it.
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Motion.hoverIntent)
            guard !Task.isCancelled, let self else { return }
            guard let hotZone = self.hotZone, hotZone.frame.insetBy(dx: 0, dy: -1).contains(NSEvent.mouseLocation) else {
                self.swell(false)
                return
            }
            self.expand()
        }
    }

    /// Grows the closed notch slightly while the pointer is on it, so it responds at once even
    /// though opening waits for the hover-intent delay.
    private func swell(_ on: Bool) {
        guard let shape = canvasView, shownPhase != .expanded, !Motion.reduceMotion else { return }
        let size = model.bodySize(for: shownPhase)
        let radii = model.radii(for: shownPhase)
        let notch = model.geometry
        shape.setShape(
            width: on ? max(size.width, notch.notchWidth) + 14 : size.width,
            height: on ? notch.notchHeight + 3 : size.height,
            topRadius: on ? max(radii.top, 5) : radii.top,
            bottomRadius: on ? max(radii.bottom, 11) : radii.bottom,
            spring: Motion.hoverSwell
        )
    }

    /// The open notch's rect on screen.
    private var openRect: CGRect {
        let size = model.bodySize(for: .expanded)
        let width = size.width + 2 * model.radii(for: .expanded).top
        return frame(for: CGSize(width: width, height: size.height))
    }

    /// While open, checks a few times a second whether the pointer has left, and closes after a
    /// moment outside. A timer is more dependable than tracking areas on a panel that switches
    /// between ignoring and accepting the mouse, and it only runs while the notch is open.
    private func startWatchingForExit() {
        guard exitWatcher == nil else { return }
        var outsideSince: Date?
        exitWatcher = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An approval keeps the notch open until it's answered.
                if self.app.agents.pendingApproval != nil
                    || self.openRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
                    outsideSince = nil
                } else if let since = outsideSince {
                    if Date().timeIntervalSince(since) > Motion.closeDelay { self.collapse() }
                } else {
                    outsideSince = Date()
                }
            }
        }
    }

    private func stopWatchingForExit() {
        exitWatcher?.invalidate()
        exitWatcher = nil
    }
}
