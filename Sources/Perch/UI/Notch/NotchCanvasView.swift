import AppKit
import QuartzCore

/// Draws the notch as black Core Animation layers that grow out of the camera, with the SwiftUI
/// content above them, masked to the same outline.
///
/// The window server runs these animations by itself, at the display's full rate (120 Hz on
/// ProMotion), whatever the app's main thread is doing. Width, height and both corner radii are
/// separate springs, so a new stage can start while the previous one is still moving.
final class NotchCanvasView: NSView {
    /// A Core Animation spring, in Apple's duration and bounce terms.
    struct Spring {
        var response: Double
        var bounce: Double
    }

    private let shapeView = NSView()
    private let contentContainer = NSView()
    private let shapeRoot = CALayer()
    private let body = CALayer()
    private let leftFlare = CAShapeLayer()
    private let rightFlare = CAShapeLayer()
    private let contentMask = CALayer()
    /// Casts a colored glow around the shape now and then; itself invisible.
    private let glowLayer = CALayer()

    /// Flares are drawn at this radius and scaled to the current one.
    private static let flareReference: CGFloat = 12

    private(set) var bodyWidth: CGFloat = 0
    private(set) var bodyHeight: CGFloat = 0

    init(content: NSView) {
        super.init(frame: .zero)

        // A layer-hosting view: Perch owns this layer tree, AppKit leaves it alone.
        shapeView.layer = shapeRoot
        shapeView.wantsLayer = true
        shapeView.autoresizingMask = [.width, .height]
        addSubview(shapeView)

        contentContainer.wantsLayer = true
        contentContainer.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        contentContainer.addSubview(content)
        addSubview(contentContainer)

        for layer in [body, contentMask] {
            layer.backgroundColor = NSColor.black.cgColor
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            // Only the bottom corners are rounded (layer coordinates start at the bottom).
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            layer.cornerCurve = .continuous
        }
        glowLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 12
        glowLayer.shadowOpacity = 0

        body.shadowColor = NSColor.black.cgColor
        body.shadowRadius = 18
        body.shadowOffset = CGSize(width: 0, height: -8)
        body.shadowOpacity = 0

        // The small inward curves where the notch meets the top edge of the screen.
        let r = Self.flareReference
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 0, y: r))
        left.addLine(to: CGPoint(x: r, y: r))
        left.addLine(to: CGPoint(x: r, y: 0))
        left.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: r, y: r))
        left.closeSubpath()
        leftFlare.path = left
        leftFlare.anchorPoint = CGPoint(x: 1, y: 1)

        let right = CGMutablePath()
        right.move(to: CGPoint(x: 0, y: 0))
        right.addLine(to: CGPoint(x: 0, y: r))
        right.addLine(to: CGPoint(x: r, y: r))
        right.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: 0, y: r))
        right.closeSubpath()
        rightFlare.path = right
        rightFlare.anchorPoint = CGPoint(x: 0, y: 1)

        for flare in [leftFlare, rightFlare] {
            flare.fillColor = NSColor.black.cgColor
            flare.bounds = CGRect(x: 0, y: 0, width: r, height: r)
        }

        shapeRoot.addSublayer(glowLayer)
        shapeRoot.addSublayer(body)
        shapeRoot.addSublayer(leftFlare)
        shapeRoot.addSublayer(rightFlare)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if contentContainer.layer?.mask !== contentMask {
            contentContainer.layer?.mask = contentMask
        }
        withoutActions {
            let top = CGPoint(x: bounds.midX, y: bounds.maxY)
            body.position = top
            contentMask.position = top
            glowLayer.position = top
            leftFlare.position = CGPoint(x: top.x - bodyWidth / 2, y: top.y)
            rightFlare.position = CGPoint(x: top.x + bodyWidth / 2, y: top.y)
        }
    }

    // MARK: Changing the shape

    /// Moves any of the four values toward a new target. `nil` leaves that value alone; a `nil`
    /// spring jumps without animating.
    func setShape(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        topRadius: CGFloat? = nil,
        bottomRadius: CGFloat? = nil,
        spring: Spring?
    ) {
        if let width {
            bodyWidth = width
            for layer in [body, contentMask] {
                animate(layer, "bounds.size.width", to: width, spring: spring)
            }
            animate(leftFlare, "position.x", to: bounds.midX - width / 2, spring: spring)
            animate(rightFlare, "position.x", to: bounds.midX + width / 2, spring: spring)
        }
        if let height {
            bodyHeight = height
            for layer in [body, contentMask] {
                animate(layer, "bounds.size.height", to: height, spring: spring)
            }
        }
        if let bottomRadius {
            for layer in [body, contentMask] {
                animate(layer, "cornerRadius", to: bottomRadius, spring: spring)
            }
        }
        if let topRadius {
            let scale = topRadius / Self.flareReference
            for flare in [leftFlare, rightFlare] {
                animate(flare, "transform.scale", to: scale, spring: spring)
            }
        }
    }

    /// Lets a soft light in `color` bloom around the shape and fade, once: the shadow of an
    /// invisible copy of the shape's final outline, blurred by the window server.
    func glow(color: NSColor) {
        withoutActions {
            glowLayer.bounds = CGRect(x: 0, y: 0, width: bodyWidth, height: bodyHeight)
            let radius = min(body.cornerRadius, bodyHeight / 2)
            glowLayer.shadowPath = CGPath(roundedRect: glowLayer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            glowLayer.shadowColor = color.cgColor
        }
        let bloom = CAKeyframeAnimation(keyPath: "shadowOpacity")
        bloom.values = [0, 0.5, 0.28, 0]
        bloom.keyTimes = [0, 0.22, 0.55, 1]
        bloom.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        bloom.duration = 2.0
        glowLayer.add(bloom, forKey: "glow")
    }

    /// Fades the drop shadow, built from the body's final outline so it costs one cheap pass.
    func setShadow(visible: Bool) {
        if visible {
            withoutActions {
                body.shadowPath = CGPath(
                    roundedRect: CGRect(x: 0, y: 0, width: bodyWidth, height: bodyHeight),
                    cornerWidth: body.cornerRadius, cornerHeight: body.cornerRadius, transform: nil
                )
            }
        }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = body.presentation()?.shadowOpacity ?? body.shadowOpacity
        fade.toValue = visible ? 0.45 : 0
        fade.duration = visible ? 0.25 : 0.06
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        withoutActions { body.shadowOpacity = visible ? 0.45 : 0 }
        body.add(fade, forKey: "shadowOpacity")
    }

    // MARK: Helpers

    private func animate(_ layer: CALayer, _ keyPath: String, to value: CGFloat, spring: Spring?) {
        let current = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        withoutActions { layer.setValue(value, forKeyPath: keyPath) }

        guard let spring else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let animation = CASpringAnimation(perceptualDuration: spring.response, bounce: spring.bounce)
        animation.keyPath = keyPath
        animation.fromValue = current
        animation.toValue = value
        animation.duration = animation.settlingDuration
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        layer.add(animation, forKey: keyPath)
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
