import AppKit
import SwiftUI

/// A connection in the agent graph, in the graph's SwiftUI coordinate space (origin top-left).
struct GraphEdge: Hashable {
    enum Flow: Hashable {
        /// Work is moving along this edge: glowing particles travel from source to target.
        case active
        /// Live but quiet (idle session, waiting for input).
        case resting
        /// Finished agents and ended sessions.
        case faded
    }

    let id: String
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let flow: Flow
}

/// Draws all edges with Core Animation. Particles and flowing dashes run in the window server, so a graph full of
/// busy agents costs the app no per-frame work (see LayerAnimations.swift for why that matters).
struct GraphEdgesView: NSViewRepresentable {
    var edges: [GraphEdge]

    func makeNSView(context: Context) -> AnimatedLayerView { AnimatedLayerView() }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        let edges = edges.map { ($0, NSColor($0.color)) }
        view.build = { layer, bounds in
            for (edge, color) in edges {
                Self.draw(edge, color: color, in: layer, height: bounds.height)
            }
        }
        view.rebuild()
    }

    private static func draw(_ edge: GraphEdge, color: NSColor, in layer: CALayer, height: CGFloat) {
        // SwiftUI measures from the top; this layer's origin is bottom-left.
        let from = CGPoint(x: edge.from.x, y: height - edge.from.y)
        let to = CGPoint(x: edge.to.x, y: height - edge.to.y)
        let bend = max(abs(to.x - from.x) * 0.5, 24)
        let path = CGMutablePath()
        path.move(to: from)
        path.addCurve(to: to, control1: CGPoint(x: from.x + bend, y: from.y), control2: CGPoint(x: to.x - bend, y: to.y))

        func stroke(width: CGFloat, alpha: CGFloat) -> CAShapeLayer {
            let line = CAShapeLayer()
            line.path = path
            line.fillColor = nil
            line.strokeColor = color.withAlphaComponent(alpha).cgColor
            line.lineWidth = width
            line.lineCap = .round
            layer.addSublayer(line)
            return line
        }

        switch edge.flow {
        case .faded:
            stroke(width: 1.2, alpha: 0.22).lineDashPattern = [2, 4]
        case .resting:
            _ = stroke(width: 1.5, alpha: 0.45)
        case .active:
            _ = stroke(width: 7, alpha: 0.10)  // soft glow under the line
            _ = stroke(width: 1.8, alpha: 0.55)
            let dashes = stroke(width: 2.2, alpha: 0.9)
            dashes.lineDashPattern = [2, 12]
            guard !LayerMotion.reduceMotion else { return }
            // Decreasing phase moves the dashes from source to target.
            dashes.add(LayerMotion.forever("lineDashPhase", from: 14, to: 0, period: 0.7), forKey: "flow")

            let length = hypot(to.x - from.x, to.y - from.y)
            let travel = max(0.9, Double(length) / 220)  // similar speed on short and long edges
            for index in 0..<2 {
                let particle = LayerMotion.dot(center: .zero, radius: 3.2, color: color.cgColor)
                particle.shadowColor = color.cgColor
                particle.shadowRadius = 5
                particle.shadowOpacity = 0.9
                particle.shadowOffset = .zero
                let motion = CAKeyframeAnimation(keyPath: "position")
                motion.path = path
                motion.calculationMode = .paced
                motion.duration = travel
                motion.repeatCount = .infinity
                motion.isRemovedOnCompletion = false
                // Two particles half a lap apart, phase tied to the global clock so rebuilds do not jump.
                motion.timeOffset = (CACurrentMediaTime() + Double(index) * travel / 2).truncatingRemainder(dividingBy: travel)
                particle.add(motion, forKey: "travel")
                let fade = LayerMotion.forever("opacity", from: 0.35, to: 1.0, period: travel / 2, autoreverses: true)
                particle.add(fade, forKey: "fade")
                layer.addSublayer(particle)
            }
        }
    }
}
