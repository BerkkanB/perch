import AppKit
import Observation

/// Where the notch is on a screen. Screens without one get a zero-width "virtual notch" at the
/// top centre, as tall as the menu bar.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var midX: CGFloat
    var hasNotch: Bool

    init(screen: NSScreen) {
        let frame = screen.frame
        screenFrame = frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = frame.width - left.width - right.width
            notchHeight = screen.safeAreaInsets.top
            midX = frame.minX + left.width + notchWidth / 2
            hasNotch = true
        } else {
            notchWidth = 0
            notchHeight = max(frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            midX = frame.midX
            hasNotch = false
        }
    }

    init(screenFrame: CGRect, notchWidth: CGFloat, notchHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        midX = screenFrame.midX
        hasNotch = notchWidth > 0
    }
}

/// The notch's state. `targetPhase` is what it should show; `NotchController` animates the
/// black shape toward it in stages and sets `contentPhase` once the shape has room for it.
@MainActor
@Observable
final class NotchModel {
    enum Phase: Equatable {
        /// Hidden inside the hardware notch.
        case idle
        /// The notch a little wider while a module is on, with its symbol beside the camera.
        case badge
        /// Wider wings for a moment after a change.
        case hud
        /// The open list, on hover or click.
        case expanded
    }

    var geometry: NotchGeometry
    var isExpanded = false
    /// Pins a phase, for screenshots and demos.
    var forcedPhase: Phase?

    /// The content inside the shape. `nil` while the shape is moving between sizes.
    var contentPhase: Phase?

    @ObservationIgnored private let app: AppModel

    init(app: AppModel, geometry: NotchGeometry) {
        self.app = app
        self.geometry = geometry
    }

    var targetPhase: Phase {
        if let forcedPhase { return forcedPhase }
        if isExpanded { return .expanded }
        if app.prefs.notchShowsHUD, app.hud.current != nil { return .hud }
        if geometry.hasNotch, app.prefs.notchShowsBadge, badgeModule != nil { return .badge }
        return .idle
    }

    /// The module the badge is about: the first one that is on.
    var badgeModule: (any PerchModule)? {
        app.modules.first { $0.isOn }
    }

    /// macOS reports the Mac as hot or very hot (the levels the heat guard acts on).
    var isRunningHot: Bool {
        let state = app.power.thermalState
        return state == .serious || state == .critical
    }

    var isCriticallyHot: Bool {
        app.power.thermalState == .critical
    }

    // MARK: Layout

    /// How far the badge extends on each side of the camera. Both sides always match, sized for
    /// the fuller one: the symbol (and a thermometer when hot) on the left, time left on the right.
    var badgeWing: CGFloat {
        if badgeModule?.timer?.isRunning == true { return 58 }
        return isRunningHot ? 50 : 32
    }

    static let hudWing: CGFloat = 124
    static let expandedWidth: CGFloat = 500
    static let shadowPadding: CGFloat = 26

    /// The open list's vertical rhythm, shared with `NotchListContent`.
    enum List {
        static let statsTop: CGFloat = 8
        static let statsHeight: CGFloat = 18
        static let statsGap: CGFloat = 10
        /// Title line, description, then the duration track.
        static let primaryHeight: CGFloat = 106
        static let trackHeight: CGFloat = 32
        static let rowHeight: CGFloat = 40
        static let rowSpacing: CGFloat = 2
        static let bottom: CGFloat = 10
        static let panelInset: CGFloat = 12
        static let rowInset: CGFloat = 14
    }

    /// The black body for `phase`, not counting the small curves at the top corners.
    func bodySize(for phase: Phase) -> CGSize {
        let width = geometry.notchWidth
        let height = geometry.notchHeight
        switch phase {
        case .idle:
            // A little smaller than the real notch so no black edge ever shows around it.
            return CGSize(width: max(0, width - 10), height: max(0, height - 2))
        case .badge:
            return CGSize(width: width + 2 * badgeWing, height: height)
        case .hud:
            return CGSize(width: width + 2 * Self.hudWing, height: height)
        case .expanded:
            return CGSize(width: max(Self.expandedWidth, width + 260), height: expandedHeight)
        }
    }

    func radii(for phase: Phase) -> (top: CGFloat, bottom: CGFloat) {
        switch phase {
        case .idle: (0, 8)
        case .badge, .hud: (6, 14)
        case .expanded: (10, 24)
        }
    }

    /// The fixed size of the panel: room for the open notch and its shadow. The panel never moves
    /// or resizes, so the shape always grows out of the centre and shrinks back into it.
    var canvasSize: CGSize {
        let open = bodySize(for: .expanded)
        let radii = radii(for: .expanded)
        return CGSize(width: open.width + 2 * radii.top + 2 * Self.shadowPadding, height: open.height + Self.shadowPadding)
    }

    var expandedHeight: CGFloat {
        let rows = CGFloat(app.secondary.count)
        return geometry.notchHeight + List.statsTop + List.statsHeight + List.statsGap
            + List.primaryHeight + rows * (List.rowHeight + List.rowSpacing) + List.bottom
    }
}
