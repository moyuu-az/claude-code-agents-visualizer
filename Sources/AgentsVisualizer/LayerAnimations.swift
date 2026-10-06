import AppKit
import SwiftUI

// Continuous animations of an always-on dashboard must not cost CPU. SwiftUI-driven animation (TimelineView or
// `repeatForever`) re-evaluates the view graph every frame, and here that re-lays out the whole dashboard:
// one spinner measured ~30-35% CPU. The same holds for repeating `symbolEffect`s (~10% CPU each) and for
// SwiftUI transitions that run on every refresh (~12% CPU on a busy dashboard). These views hand the animation
// to Core Animation instead, which runs it in the window server; the app itself does no per-frame work
// (measured ~0-1%).

/// Layer-backed view that (re)builds its layers on size or appearance changes and never takes mouse events,
/// so it can sit inside SwiftUI buttons and rows.
final class AnimatedLayerView: NSView {
    var build: (CALayer, CGRect) -> Void = { _, _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        LayerMotion.observeReduceMotion(self, #selector(rebuild))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); rebuild() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuild() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); rebuild() }
    // Bitmap contents (symbol images) are rendered for the screen's scale; redo them on another display.
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); rebuild() }

    @objc func rebuild() {
        guard let layer, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        effectiveAppearance.performAsCurrentDrawingAppearance { build(layer, bounds) }
    }
}

enum LayerMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Calls `action` on `target` when Reduce Motion is switched: animations are baked into the layers when
    /// they are built, so they have to be rebuilt to start or stop.
    static func observeReduceMotion(_ target: NSObject, _ action: Selector) {
        NSWorkspace.shared.notificationCenter.addObserver(
            target, selector: action, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    static func forever(_ keyPath: String, from: Any, to: Any, period: CFTimeInterval, autoreverses: Bool = false) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.autoreverses = autoreverses
        if autoreverses { animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
        return looping(animation, period: period)
    }

    /// Repeats `animation` endlessly with its phase following the global clock, so rebuilding a layer does not
    /// make it jump.
    static func looping<Animation: CAAnimation>(_ animation: Animation, period: CFTimeInterval) -> Animation {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period * (animation.autoreverses ? 2 : 1))
        return animation
    }

    /// A short left-right shake, then a rest: SF Symbols' periodic wiggle.
    static func wiggle(period: CFTimeInterval = 2.6) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [0, 0.22, -0.22, 0.14, -0.08, 0, 0]
        animation.keyTimes = [0, 0.06, 0.14, 0.22, 0.3, 0.38, 1]
        return looping(animation, period: period)
    }

    static func circle(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    static func dot(center: CGPoint, radius: CGFloat, color: CGColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = circle(center: center, radius: radius)
        layer.fillColor = color
        return layer
    }

    /// Container that spins around its centre.
    static func spinner(in bounds: CGRect, period: CFTimeInterval, phase: CGFloat = 0) -> CALayer {
        let container = CALayer()
        container.frame = bounds
        container.setAffineTransform(CGAffineTransform(rotationAngle: phase))
        if !reduceMotion {
            container.add(forever("transform.rotation.z", from: phase, to: phase + 2 * .pi, period: period), forKey: "spin")
        }
        return container
    }
}

/// Spinning arc with a fading tail: the "running" indicator for sessions and agents.
struct SpinnerRing: NSViewRepresentable {
    var color: Color
    var lineWidth: CGFloat = 2
    var showsTrack = true
    var showsCore = true
    var period: CFTimeInterval = 1.1

    func makeNSView(context: Context) -> AnimatedLayerView { AnimatedLayerView() }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        let (color, lineWidth, showsTrack, showsCore, period) = (NSColor(color), lineWidth, showsTrack, showsCore, period)
        view.build = { layer, bounds in
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2 - lineWidth / 2
            if showsTrack {
                let track = CAShapeLayer()
                track.path = LayerMotion.circle(center: center, radius: radius)
                track.fillColor = nil
                track.strokeColor = color.withAlphaComponent(0.2).cgColor
                track.lineWidth = lineWidth
                layer.addSublayer(track)
            }
            let spinner = LayerMotion.spinner(in: bounds, period: period)
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.frame = bounds
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
            let arc = CAShapeLayer()
            arc.path = LayerMotion.circle(center: center, radius: radius)
            arc.fillColor = nil
            arc.strokeColor = NSColor.black.cgColor
            arc.lineWidth = lineWidth
            arc.lineCap = .round
            arc.strokeEnd = 0.75
            gradient.mask = arc
            spinner.addSublayer(gradient)
            layer.addSublayer(spinner)
            if showsCore {
                layer.addSublayer(LayerMotion.dot(center: center, radius: radius * 0.38, color: color.cgColor))
            }
        }
        view.rebuild()
    }
}

/// The session as a planet with its running agents orbiting it, each trailing a short comet tail.
struct OrbitView: NSViewRepresentable {
    /// One colour per running agent.
    var satellites: [Color]
    var coreColor: Color = .green

    func makeNSView(context: Context) -> AnimatedLayerView { AnimatedLayerView() }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        let satellites = satellites.map(NSColor.init)
        let core = NSColor(coreColor)
        view.build = { layer, bounds in
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) / 2 - 4
            let ring = CAShapeLayer()
            ring.path = LayerMotion.circle(center: center, radius: radius)
            ring.fillColor = nil
            ring.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor
            ring.lineWidth = 0.75
            layer.addSublayer(ring)

            let halo = LayerMotion.dot(center: center, radius: 7, color: core.withAlphaComponent(0.2).cgColor)
            if !LayerMotion.reduceMotion {
                halo.add(LayerMotion.forever("opacity", from: 0.35, to: 1.0, period: 1.2, autoreverses: true), forKey: "breathe")
            }
            layer.addSublayer(halo)
            layer.addSublayer(LayerMotion.dot(center: center, radius: 4, color: core.cgColor))

            for (index, color) in satellites.enumerated() {
                // Evenly spaced and at slightly different speeds so they never move in lockstep.
                let phase = CGFloat(index) / CGFloat(satellites.count) * 2 * .pi
                let arm = LayerMotion.spinner(in: bounds, period: 2.6 + Double(index % 3) * 0.45, phase: phase)
                for step in 0...5 {
                    let angle = -CGFloat(step) * 0.16
                    let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    let size = step == 0 ? 3.2 : 2.4 - CGFloat(step) * 0.28
                    let alpha = step == 0 ? 1 : 0.55 - CGFloat(step) * 0.09
                    arm.addSublayer(LayerMotion.dot(center: point, radius: size, color: color.withAlphaComponent(alpha).cgColor))
                }
                layer.addSublayer(arm)
            }
        }
        view.rebuild()
    }
}

/// Dashes flowing from a session to an agent while the agent works.
struct FlowLine: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> AnimatedLayerView { AnimatedLayerView() }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        let color = NSColor(color)
        view.build = { layer, bounds in
            let line = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            line.path = path
            line.strokeColor = color.cgColor
            line.lineWidth = 1.5
            line.lineCap = .round
            line.lineDashPattern = [3, 3]
            if !LayerMotion.reduceMotion {
                // Decreasing phase moves the dashes toward the end of the line, i.e. into the agent.
                line.add(LayerMotion.forever("lineDashPhase", from: 6, to: 0, period: 0.45), forKey: "flow")
            }
            layer.addSublayer(line)
        }
        view.rebuild()
    }
}

/// Soft breathing fill, used behind sessions that wait for the user.
struct BreathingFill: NSViewRepresentable {
    var color: Color
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> AnimatedLayerView { AnimatedLayerView() }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        let (color, cornerRadius) = (NSColor(color), cornerRadius)
        view.build = { layer, bounds in
            let fill = CALayer()
            fill.frame = bounds
            fill.cornerRadius = cornerRadius
            fill.cornerCurve = .continuous
            fill.backgroundColor = color.cgColor
            fill.opacity = 0.6
            if !LayerMotion.reduceMotion {
                fill.add(LayerMotion.forever("opacity", from: 0.3, to: 1.0, period: 1.3, autoreverses: true), forKey: "breathe")
            }
            layer.addSublayer(fill)
        }
        view.rebuild()
    }
}

/// SF Symbol that keeps pulsing or wiggling to draw the eye, e.g. to a session waiting for the user.
struct AnimatedSymbol: NSViewRepresentable {
    enum Motion { case pulse, wiggle }

    var systemName: String
    var color: Color
    var pointSize: CGFloat
    var motion: Motion

    private var image: NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
    }

    func makeNSView(context: Context) -> AnimatedLayerView { AnimatedLayerView() }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        let (image, color, motion) = (image, NSColor(color), motion)
        view.build = { layer, bounds in
            guard let image else { return }
            // The colour shows through the symbol's shape, like SwiftUI's monochrome `foregroundStyle`, so
            // cut-outs such as the "!" of a filled bubble stay transparent (a palette colour would fill them).
            let symbol = CALayer()
            symbol.frame = bounds  // rotates around the centre
            symbol.backgroundColor = color.cgColor
            let shape = CALayer()
            shape.frame = symbol.bounds
            shape.contentsGravity = .center
            shape.contentsScale = layer.contentsScale
            shape.contents = image.layerContents(forContentsScale: layer.contentsScale)
            symbol.mask = shape
            if !LayerMotion.reduceMotion {
                switch motion {
                case .pulse:
                    symbol.add(LayerMotion.forever("opacity", from: 1.0, to: 0.35, period: 0.8, autoreverses: true), forKey: "pulse")
                case .wiggle:
                    symbol.add(LayerMotion.wiggle(), forKey: "wiggle")
                }
            }
            layer.addSublayer(symbol)
        }
        view.rebuild()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedLayerView, context: Context) -> CGSize? {
        image?.size
    }
}

/// A one-line label whose new text pushes in from below, with an optional highlight sweeping across it: the
/// "working on it" shimmer.
struct ShimmerText: NSViewRepresentable {
    var text: String
    var shimmers = true
    var font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)

    /// Clips the label: a push transition moves the label's layer as a whole, past its own bounds and mask, so
    /// without a clipping superview the outgoing text would slide over the row above.
    final class Ticker: NSView {
        let label = NSTextField(labelWithString: "")
        var shimmers = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            clipsToBounds = true
            label.wantsLayer = true
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.textColor = .secondaryLabelColor
            addSubview(label)
            LayerMotion.observeReduceMotion(self, #selector(installShimmer))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            label.frame = bounds
            installShimmer()
        }

        @objc func installShimmer() {
            guard shimmers, let layer = label.layer, bounds.width > 0 else { return }
            let mask = CAGradientLayer()
            let band = max(bounds.width, 60)
            // A wide gradient with a bright band in the middle slides across the text.
            mask.frame = CGRect(x: -band, y: 0, width: bounds.width + band * 2, height: bounds.height)
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            let dim = NSColor.black.withAlphaComponent(0.55).cgColor, bright = NSColor.black.cgColor
            mask.colors = [dim, dim, bright, dim, dim]
            mask.locations = [0, 0.38, 0.5, 0.62, 1]
            if !LayerMotion.reduceMotion {
                mask.add(LayerMotion.forever("position.x", from: mask.position.x - band, to: mask.position.x + band, period: 2.2),
                         forKey: "sweep")
            }
            layer.mask = mask
        }

        /// Pushes `text` in from below, like a ticker. Core Animation runs it: a SwiftUI transition here re-lays
        /// out the whole dashboard on every frame, and activity text changes on nearly every refresh.
        func show(_ text: String) {
            guard label.stringValue != text else { return }
            if !LayerMotion.reduceMotion, !label.stringValue.isEmpty, let layer = label.layer {
                let push = CATransition()
                push.type = .push
                push.subtype = .fromBottom  // in this unflipped view; under a flipped superview it comes from the top
                push.duration = 0.3
                push.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(push, forKey: "ticker")
            }
            label.stringValue = text
        }
    }

    func makeNSView(context: Context) -> Ticker { Ticker() }

    func updateNSView(_ ticker: Ticker, context: Context) {
        ticker.shimmers = shimmers
        ticker.label.font = font
        ticker.show(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Ticker, context: Context) -> CGSize? {
        // Takes the offered width, not the text's: SwiftUI does not measure this view again when only the text
        // changes, so a text-sized width would truncate a longer new text. It also keeps text changes layout-free.
        let natural = nsView.label.intrinsicContentSize
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural.width
        return CGSize(width: width, height: natural.height)
    }
}
