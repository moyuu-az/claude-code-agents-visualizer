import AgentsVisualizerCore
import SwiftUI

// MARK: - Liquid Glass with a material fallback

extension View {
    /// Liquid Glass on macOS 26+, a translucent material before that.
    @ViewBuilder
    func glassSurface(_ shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint.opacity(0.35)) }
            }
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

/// Lets neighbouring glass shapes blend into each other on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Ambient background

/// Soft colour field behind the glass. Its hue follows the overall state (orange when something needs you,
/// green while work runs), so the window's mood is readable from across the room.
struct AmbientBackground: View {
    let mood: SessionStatus
    @Environment(\.colorScheme) private var colorScheme

    private var palette: [Color] {
        switch mood {
        case .needsInput: [.orange, .pink, .yellow]
        case .running: [.green, .teal, .cyan]
        case .idle: [.blue, .indigo, .teal]
        case .ended: [.indigo, .purple, .blue]
        }
    }

    var body: some View {
        let strength = colorScheme == .dark ? 0.30 : 0.22
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if #available(macOS 15.0, *) {
                // Deliberately static: every glass surface re-samples the backdrop, so an animated backdrop
                // costs a full-window recomposition per frame. Only the mood change is animated.
                MeshGradient(width: 3, height: 3, points: Self.points, colors: meshColors)
                    .opacity(strength)
            } else {
                LinearGradient(colors: palette.map { $0.opacity(strength) }, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: mood)
    }

    private var meshColors: [Color] {
        let (a, b, c) = (palette[0], palette[1], palette[2])
        return [a, .clear, b, .clear, c, .clear, b, .clear, a]
    }

    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.55, 0], [1, 0],
        [0, 0.45], [0.6, 0.55], [1, 0.4],
        [0, 1], [0.4, 1], [1, 1],
    ]
}

// MARK: - Agent identity

extension AgentInfo {
    /// Stable per-type colour (String.hashValue is randomised per launch, so hash the scalars ourselves).
    var typeColor: Color {
        let palette: [Color] = [.teal, .indigo, .pink, .mint, .cyan, .purple, .blue]
        let hash = agentType.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    var typeSymbol: String {
        switch agentType {
        case "code-reviewer": "checkmark.seal.fill"
        case "deep-reviewer": "eye.fill"
        case "Explore": "binoculars.fill"
        case "Plan": "map.fill"
        case "general-purpose": "sparkles"
        case "claude-code-guide": "book.fill"
        default: "cpu"
        }
    }
}

/// Agent badge: a type icon, wrapped in a spinning gradient ring while the agent works.
struct AgentAvatar: View {
    let agent: AgentInfo
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(agent.typeColor.opacity(agent.status.isActive ? 0.25 : 0.12))
            Image(systemName: agent.typeSymbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(agent.status.isActive ? agent.typeColor : .secondary)
            if agent.status.isActive {
                SpinnerRing(color: agent.typeColor, lineWidth: 2, showsTrack: false, showsCore: false, period: 1.4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Agent orbit

/// The session as a small planet with its running agents orbiting it.
struct AgentOrbit: View {
    let agents: [AgentInfo]
    var size: CGFloat = 40

    var body: some View {
        let running = agents.filter(\.status.isActive)
        OrbitView(satellites: running.map(\.typeColor))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text("\(running.count) agents running"))
    }
}

// MARK: - Connectors and status

/// "├" / "└" connector from a session to an agent. While the agent runs, dashes flow toward it.
struct TreeConnector: View {
    let isLast: Bool
    let isFlowing: Bool
    var color: Color = .green

    var body: some View {
        Canvas { canvas, size in
            let x = size.width / 2, mid = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: isLast ? mid : size.height))
            if !isFlowing {
                path.move(to: CGPoint(x: x, y: mid))
                path.addLine(to: CGPoint(x: size.width, y: mid))
            }
            canvas.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        }
        .overlay(alignment: .trailing) {
            if isFlowing { FlowLine(color: color).frame(width: 8) }
        }
        .frame(width: 14)
        .accessibilityHidden(true)
    }
}

/// Spinning ring used as the "running" status of a session.
struct RunningRing: View {
    var color: Color = .green
    var size: CGFloat = 14

    var body: some View {
        SpinnerRing(color: color).frame(width: size, height: size)
    }
}
