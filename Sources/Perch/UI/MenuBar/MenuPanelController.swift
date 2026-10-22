import AppKit
import SwiftUI

/// The panel under the menu bar icon: the same black list as the open notch, with no arrow.
/// Closes on a click elsewhere, on Esc, or when another app takes focus.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: MenuPanel
    private let hosting: SizeReportingHostingView<AnyView>
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private weak var anchor: NSStatusBarButton?

    static let cornerRadius: CGFloat = 20

    init(app: AppModel) {
        panel = MenuPanel()
        hosting = SizeReportingHostingView(rootView: AnyView(MenuPanelView().environment(app)))
        super.init()

        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onSizeChange = { [weak self] _ in self?.fitToContent() }

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.cgColor
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        background.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background
        panel.delegate = self
    }

    var isShown: Bool { panel.isVisible }
    var window: NSWindow { panel }

    func show(below button: NSStatusBarButton) {
        guard !panel.isVisible else { return }
        anchor = button
        fitToContent()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        onVisibilityChange?(true)
    }

    func close() {
        guard panel.isVisible else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
        onVisibilityChange?(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Sizes the panel to its content and hangs it just below the menu bar icon, the way
    /// system menus do: left edges aligned, kept inside the screen.
    private func fitToContent() {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        var origin = panel.frame.origin
        if let button = anchor, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = buttonWindow.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero
            origin.x = min(buttonFrame.minX - 8, visible.maxX - size.width - 8)
            origin.x = max(origin.x, visible.minX + 8)
            origin.y = visible.maxY - 6 - size.height
        } else {
            origin.y = panel.frame.maxY - size.height
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }
}

/// Borderless panel that can be key (for Esc and the segmented control) without activating Perch.
final class MenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reports when its SwiftUI content changes size, so the panel can follow.
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((NSSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.fittingSize)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
