import AppKit
import SwiftUI

/// System colors only, so states read the same as elsewhere in macOS.
enum Palette {
    static let stayAwake = Color.orange
    static let screenOn = Color.blue
    static let sleep = Color.indigo
    static let good = Color.green
    static let warning = Color.yellow
    static let danger = Color.red
}

/// The type and grays of Perch's black surfaces (the notch and the menu bar panel). Both are
/// always dark, like the hardware notch they grow out of.
enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let separator = Color.white.opacity(0.22)
    static let chip = Color.white.opacity(0.10)
    static let chipSelected = Color.white.opacity(0.22)
    static let hover = Color.white.opacity(0.06)

    static let title = Font.system(size: 16)
    static let compactTitle = Font.system(size: 15)
    static let body = Font.system(size: 13)
    static let chipText = Font.system(size: 12.5)
    static let stats = Font.system(size: 12.5, design: .monospaced)
}

/// Timing follows Apple's spring model (WWDC23 "Animate with springs"): bounce 0 when in doubt,
/// about 0.15 for brisk motion with a hint of overshoot, closing without bounce. The durations sit
/// with those of the open-source notch apps (Boring Notch opens in 0.42 s and closes without
/// bounce; DynamicNotchKit uses 0.4 s).
enum Motion {
    // The notch opens in two moves: it stretches sideways from the camera as a line, then drops
    // down. Closing runs them backwards. These are Core Animation springs, which the window
    // server runs at the display's full rate.
    static let stretch = NotchCanvasView.Spring(response: 0.38, bounce: 0.15)
    static let drop = NotchCanvasView.Spring(response: 0.42, bounce: 0.15)
    static let lift = NotchCanvasView.Spring(response: 0.36, bounce: 0)
    static let retract = NotchCanvasView.Spring(response: 0.38, bounce: 0)
    /// Badge and HUD wings coming out, and going back in.
    static let wingsOut = NotchCanvasView.Spring(response: 0.35, bounce: 0.15)
    static let wingsIn = NotchCanvasView.Spring(response: 0.30, bounce: 0)
    /// The notch swells a little the moment the pointer reaches it, before it opens.
    static let hoverSwell = NotchCanvasView.Spring(response: 0.25, bounce: 0.15)

    static let contentIn = Animation.smooth(duration: 0.25)
    static let contentOut = Animation.easeIn(duration: 0.15)
    static let selection = Animation.snappy(duration: 0.3)
    static let hover = Animation.easeOut(duration: 0.15)
    /// Replaces every animation above while Reduce Motion is on: cross-fades only.
    static let reduced = Animation.easeInOut(duration: 0.2)

    // StandBy: the screen goes black, then the clock settles in from a little small and blurred,
    // with the agents and readings a beat apart. Closing zooms it toward you as it fades, like
    // unlocking, while the black lifts.
    static let standbyIn = Animation.smooth(duration: 0.8)
    static let standbyOut = Animation.easeIn(duration: 0.28)
    /// Between one part of StandBy coming in and the next.
    static let standbyStagger = 0.1
    /// The black fading in: quick when you open StandBy, slow like dimming when the Mac is idle.
    static let standbyFadeIn: TimeInterval = 0.45
    static let standbyIdleFadeIn: TimeInterval = 1.4
    static let standbyFadeOut: TimeInterval = 0.4

    /// How long the pointer rests on the notch before it opens (0.3–0.5 s is the usual range).
    static let hoverIntent: Duration = .milliseconds(300)
    /// How long the pointer can be outside before the open notch closes.
    static let closeDelay: TimeInterval = 0.4

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
