import AppKit
import SwiftUI

// The collapsed notch's agent badge changes every few seconds for as long as an agent works: a
// new file or command, or the next agent's turn. Animated by SwiftUI, every frame of every such
// change laid out and redrew the whole notch on the main thread, at 120 Hz on ProMotion. The
// views here draw each change once and leave the animation to Core Animation, which the window
// server plays by itself.

/// A Core Animation cross-fade.
struct LayerFade {
    var duration: CFTimeInterval
    var timing: CAMediaTimingFunctionName

    /// The next agent's turn in the badge, as SwiftUI's `.easeInOut(duration: 0.35)` did.
    static let rotation = LayerFade(duration: 0.35, timing: .easeInEaseOut)
    /// A new glance from the same agent, as SwiftUI's `.easeOut(duration: 0.2)` did.
    static let glance = LayerFade(duration: 0.2, timing: .easeOut)

    var timingFunction: CAMediaTimingFunction { CAMediaTimingFunction(name: timing) }

    /// Cross-fades `layer` from what it shows now to what it shows once this transaction commits.
    func play(on layer: CALayer?) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = timingFunction
        layer?.add(transition, forKey: kCATransition)
    }
}

/// Which agent the badge shows, and whether it got there by taking turns. Only turns fade, as
/// before; an agent that needs you takes over at once.
struct BadgeTurn: Equatable {
    var sessionID: String
    var rotation: Int

    static func fade(from old: BadgeTurn, to new: BadgeTurn) -> LayerFade? {
        old.sessionID != new.sessionID && old.rotation != new.rotation ? .rotation : nil
    }
}

// MARK: Cross-fading SwiftUI content

/// SwiftUI content in a hosting view of its own, filling the width it's offered with the content
/// leading, that cross-fades in Core Animation when `key` changes and `fade` says how.
struct LayerCrossfade<Key: Equatable, Content: View>: NSViewRepresentable {
    var key: Key
    var fade: (_ old: Key, _ new: Key) -> LayerFade?
    var content: Content

    init(key: Key, fade: @escaping (_ old: Key, _ new: Key) -> LayerFade?, @ViewBuilder content: () -> Content) {
        self.key = key
        self.fade = fade
        self.content = content()
    }

    func makeNSView(context: Context) -> LayerCrossfadeView<Key> {
        LayerCrossfadeView()
    }

    func updateNSView(_ view: LayerCrossfadeView<Key>, context: Context) {
        if let old = view.key, old != key, view.window != nil, let fade = fade(old, key) {
            fade.play(on: view.layer)
        }
        view.key = key
        view.hosting.rootView = AnyView(
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .environment(\.colorScheme, context.environment.colorScheme)
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerCrossfadeView<Key>, context: Context) -> CGSize? {
        let ideal = nsView.hosting.fittingSize
        // All the width offered, so the faded layer keeps its size from one agent to the next.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal.width
        return CGSize(width: width, height: ideal.height)
    }
}

final class LayerCrossfadeView<Key>: NSView {
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var key: Key?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: The right wing

/// The badge's right wing: a symbol and the file or command against the trailing edge, in the
/// agent's state color ("✎ middleware.ts"), laid out as `HStack(spacing: 5)` padded 14 from it.
///
/// SwiftUI draws the text, in a hosting view of its own, and an image view shows the symbol. A
/// new glance cross-fades the text in place and swaps the symbol with the system's replace
/// effect: the old one shrinks away where it was, the new one grows in where it belongs. The
/// next agent's turn cross-fades the whole wing.
struct GlanceWing: NSViewRepresentable {
    var turn: BadgeTurn
    var glance: AgentGlance
    var color: Color

    func makeNSView(context: Context) -> GlanceWingView {
        GlanceWingView()
    }

    func updateNSView(_ view: GlanceWingView, context: Context) {
        view.show(.init(turn: turn, glance: glance, color: color), colorScheme: context.environment.colorScheme)
    }
}

final class GlanceWingView: NSView {
    struct Content: Equatable {
        var turn: BadgeTurn
        var glance: AgentGlance
        var color: Color
    }

    static let trailingPadding: CGFloat = 14
    static let spacing: CGFloat = 5
    static let fontSize: CGFloat = 12.5
    static let symbol = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold, scale: .medium)

    /// Covers the whole wing and keeps its size, so its cross-fade has nothing to stretch.
    private let textBox = NSView()
    private let textHost = NSHostingView(rootView: AnyView(EmptyView()))
    /// The text's size in the room it has.
    private var textSize: CGSize = .zero
    /// Never shown: measures symbols as SwiftUI lays them out.
    private let symbolProbe = NSHostingView(rootView: AnyView(EmptyView()))
    private var layoutWidths: [String: CGFloat] = [:]
    private var symbolView: NSImageView?
    private var shown: Content?
    private var colorScheme: ColorScheme?
    private var laidOutSize: CGSize?
    /// Changes with every update, so a late step of an earlier one stands down.
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        textBox.wantsLayer = true
        textBox.autoresizingMask = [.width, .height]
        textBox.frame = bounds
        textHost.sizingOptions = [.intrinsicContentSize]
        symbolProbe.sizingOptions = [.intrinsicContentSize]
        symbolProbe.isHidden = true
        addSubview(textBox)
        textBox.addSubview(textHost)
        addSubview(symbolProbe)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ content: Content, colorScheme: ColorScheme) {
        let old = shown
        let schemeChanged = colorScheme != self.colorScheme
        guard content != old || schemeChanged else { return }
        shown = content
        generation += 1
        if schemeChanged {
            self.colorScheme = colorScheme
            appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        }

        guard let old, window != nil, old.turn.sessionID == content.turn.sessionID else {
            // First showing, or another agent: at once, or as one cross-fade when it's their turn.
            if let old, window != nil { BadgeTurn.fade(from: old.turn, to: content.turn)?.play(on: layer) }
            updateText()
            setSymbol(content.glance.symbol, color: content.color)
            place()
            return
        }

        // A new glance from the same agent.
        if old.glance.text != content.glance.text || old.color != content.color {
            LayerFade.glance.play(on: textBox.layer)
        }
        updateText()
        let oldFrame = symbolView?.frame
        let frames = frames()
        updateSymbol(from: old, to: content, oldFrame: oldFrame, newFrame: frames.symbol)
        textHost.frame = frames.text
    }

    override func layout() {
        super.layout()
        // Only for a new size: moving the symbol now could cut short a replace in progress.
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        updateText()
        place()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Measured on another scale: measure again.
        layoutWidths.removeAll()
        textKey = nil
        laidOutSize = nil
        needsLayout = true
    }

    // MARK: Text

    private struct TextKey: Equatable {
        var text: String
        var color: Color
        var room: CGFloat
        var colorScheme: ColorScheme?
    }

    private var textKey: TextKey?

    /// Draws the text in the room the symbol leaves it, truncated the way the row truncated it,
    /// unless it's already there.
    private func updateText() {
        guard let shown else { return }
        let symbolRoom = shown.glance.symbol.map { layoutWidth($0) + Self.spacing } ?? 0
        let key = TextKey(
            text: shown.glance.text, color: shown.color,
            room: max(0, bounds.width - Self.trailingPadding - symbolRoom), colorScheme: colorScheme
        )
        guard key != textKey else { return }
        textKey = key
        textHost.rootView = AnyView(
            ProposedWidth(width: key.room) {
                Text(key.text)
                    .font(.system(size: Self.fontSize))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(key.color)
            }
            .environment(\.colorScheme, key.colorScheme ?? .dark)
        )
        textSize = textHost.fittingSize
    }

    // MARK: Symbol

    /// The symbol fades in or out, slides with the text, or is swapped with the replace effect.
    private func updateSymbol(from old: Content, to new: Content, oldFrame: CGRect?, newFrame: CGRect?) {
        let tint = NSColor(new.color)
        guard let name = new.glance.symbol else {
            // The symbol goes, fading out where it was.
            guard let view = symbolView else { return }
            symbolView = nil
            animate { view.animator().alphaValue = 0 } completion: { view.removeFromSuperview() }
            return
        }
        guard let view = symbolView, let oldName = old.glance.symbol else {
            // A symbol comes, fading in where it belongs.
            let view = makeSymbolView(image: Self.image(name), tint: tint)
            view.frame = newFrame ?? .zero
            view.alphaValue = 0
            animate { view.animator().alphaValue = 1 }
            return
        }
        if oldName == name {
            // The same symbol moves with the text, and changes color with it.
            if old.color != new.color {
                LayerFade.glance.play(on: view.layer)
                view.contentTintColor = tint
            }
            if let newFrame, newFrame != oldFrame {
                animate { view.animator().frame = newFrame }
            }
            return
        }
        // Another symbol, swapped with the system's replace effect.
        guard let image = Self.image(name) else {
            setSymbol(name, color: new.color)
            return
        }
        guard let oldFrame, let newFrame, newFrame != oldFrame || old.color != new.color else {
            view.setSymbolImage(image, contentTransition: .replace)
            return
        }
        // It belongs elsewhere, or in another color. The old symbol leaves where it was: the
        // effect centers both symbols in a box the new one's size, so the view takes that size
        // around the old symbol's center. Once the old one is gone, as the new one starts to
        // grow in, the view moves to where that belongs and takes its color, unseen.
        view.frame = pixelAligned(CGRect(
            x: oldFrame.midX - newFrame.width / 2, y: oldFrame.midY - newFrame.height / 2,
            width: newFrame.width, height: newFrame.height
        ))
        view.setSymbolImage(image, contentTransition: .replace)
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration(of: oldName)) { [weak self, weak view] in
            guard let self, let view, self.generation == generation else { return }
            view.contentTintColor = tint
            view.frame = newFrame
        }
    }

    /// How long the replace effect takes to take `name` away, with a little to spare for the
    /// effect starting a frame late. Read off its frames: symbols that shrink away are gone in
    /// about a quarter second, the fuller ones a little later; since macOS 26 the globe and the
    /// checkmark draw themselves away, more slowly. Moving a moment early or late shows, at
    /// most, a speck of a symbol hopping.
    static func exitDuration(of name: String) -> TimeInterval {
        if #available(macOS 26, *) {
            switch name {
            case "globe": return 0.8
            case "checkmark": return 0.46
            default: break
            }
        }
        switch name {
        case "checklist", "hammer", "hand.raised.fill", "questionmark.bubble", "questionmark.bubble.fill": return 0.3
        default: return 0.26
        }
    }

    /// Shows `name` at once, without an effect.
    private func setSymbol(_ name: String?, color: Color) {
        guard let name else {
            symbolView?.removeFromSuperview()
            symbolView = nil
            return
        }
        if let view = symbolView {
            view.image = Self.image(name)
            view.contentTintColor = NSColor(color)
        } else {
            makeSymbolView(image: Self.image(name), tint: NSColor(color))
        }
    }

    /// A new image view, which becomes the symbol view; the one before it is taken away.
    @discardableResult
    private func makeSymbolView(image: NSImage?, tint: NSColor) -> NSImageView {
        let view = NSImageView()
        view.wantsLayer = true
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.symbolConfiguration = Self.symbol
        view.image = image
        view.contentTintColor = tint
        view.setAccessibilityElement(false)
        addSubview(view, positioned: .below, relativeTo: textBox)
        symbolView?.removeFromSuperview()
        symbolView = view
        return view
    }

    private static func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func imageSize(_ name: String) -> CGSize {
        image(name)?.withSymbolConfiguration(symbol)?.size ?? .zero
    }

    /// The width SwiftUI gives `name` in a row, at this window's scale, which for some symbols is
    /// a little less than the image's. Asked of SwiftUI itself, once per symbol.
    private func layoutWidth(_ name: String) -> CGFloat {
        if let width = layoutWidths[name] { return width }
        symbolProbe.rootView = AnyView(Image(systemName: name).font(.system(size: 10.5, weight: .semibold)))
        let width = symbolProbe.fittingSize.width
        if window != nil { layoutWidths[name] = width }
        return width
    }

    // MARK: Layout

    /// Where the symbol and the text go, as SwiftUI's row put them: trailing, the text truncating
    /// in the middle when the wing is too narrow, each centered vertically, the symbol's image
    /// centered on its slot, all on whole pixels.
    private func frames() -> (symbol: CGRect?, text: CGRect) {
        let name = shown?.glance.symbol
        let slot = name.map(layoutWidth)
        let trailing = bounds.width - Self.trailingPadding
        let text = CGRect(x: trailing - textSize.width, y: (bounds.height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        let symbolFrame = name.map { name -> CGRect in
            let image = Self.imageSize(name)
            let slotMidX = text.minX - Self.spacing - (slot ?? image.width) / 2
            return CGRect(x: slotMidX - image.width / 2, y: (bounds.height - image.height) / 2, width: image.width, height: image.height)
        }
        return (symbolFrame.map(pixelAligned), pixelAligned(text))
    }

    private func pixelAligned(_ rect: CGRect) -> CGRect {
        let scale = window?.backingScaleFactor ?? 2
        func round(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(x: round(rect.minX), y: round(rect.minY), width: round(rect.width), height: round(rect.height))
    }

    private func place() {
        let frames = frames()
        if let symbol = frames.symbol { symbolView?.frame = symbol }
        textHost.frame = frames.text
    }

    /// Runs `changes` to the views' animators as a Core Animation animation, timed like a glance.
    private func animate(_ changes: () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = LayerFade.glance.duration
            context.timingFunction = LayerFade.glance.timingFunction
            changes()
        } completionHandler: {
            completion?()
        }
    }
}

/// Offers its content `width` and takes the size the content picks, as a row does for the text
/// beside a symbol: how wide a line truncated to fit comes out.
private struct ProposedWidth: Layout {
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: proposal.height))
    }
}
