import CoreGraphics

/// Geometry of one project on the graph page: the project node, its sessions in two staggered columns, and each
/// session's agents in a column to their right.
///
/// The second session column sits half a row lower than the first, so every session's centre lines up with the gap
/// between two cards of the other column. Edges run straight through those gaps instead of under cards, and n sessions
/// take about n/2 rows instead of n. That only holds while every session card is exactly `session` sized.
public struct GraphRowLayout: Sendable {
    public var projectWidth: CGFloat
    public var session: CGSize
    /// Between the project and the sessions, and between the sessions and the agents.
    public var columnGap: CGFloat
    /// Between the two session columns.
    public var zigzagGap: CGFloat
    /// Between two cards of one session column; edges from the other column pass through it.
    public var rowGap: CGFloat
    /// Between the agent stacks of consecutive sessions.
    public var agentGap: CGFloat

    public init(projectWidth: CGFloat, session: CGSize, columnGap: CGFloat, zigzagGap: CGFloat, rowGap: CGFloat,
                agentGap: CGFloat) {
        self.projectWidth = projectWidth
        self.session = session
        self.columnGap = columnGap
        self.zigzagGap = zigzagGap
        self.rowGap = rowGap
        self.agentGap = agentGap
    }

    public struct Frames: Equatable, Sendable {
        public var project: CGRect
        public var sessions: [CGRect]
        /// `nil` for sessions without agents on screen.
        public var agents: [CGRect?]
        public var size: CGSize
    }

    public var firstColumnX: CGFloat { projectWidth + columnGap }
    public var secondColumnX: CGFloat { firstColumnX + session.width + zigzagGap }
    public var agentsX: CGFloat { secondColumnX + session.width + columnGap }

    /// `agentStacks[i]` is the size of session i's agent stack, `nil` when it has none.
    public func frames(projectHeight: CGFloat, agentStacks: [CGSize?]) -> Frames {
        let pitch = session.height + rowGap
        let sessionsHeight = agentStacks.isEmpty ? 0 : CGFloat(agentStacks.count - 1) * pitch / 2 + session.height
        var project = CGRect(x: 0, y: (sessionsHeight - projectHeight) / 2, width: projectWidth, height: projectHeight)
        let top = max(0, -project.minY)  // a project taller than its sessions: centre the sessions on it instead
        project.origin.y += top
        let sessions = agentStacks.indices.map { index in
            CGRect(origin: CGPoint(x: index.isMultiple(of: 2) ? firstColumnX : secondColumnX,
                                   y: top + CGFloat(index / 2) * pitch + (index.isMultiple(of: 2) ? 0 : pitch / 2)),
                   size: session)
        }
        // Each stack is centred on its session unless the previous stack is in the way, then it is pushed down. Stacks
        // never start above the first session: centring a tall one there would move every session of the project each
        // time an agent starts or finishes.
        // ponytail: greedy, so one tall stack pushes every later one below its session; fine for the few sessions
        // that have agents at once. Balance the drift up and down if graphs with many busy sessions look skewed.
        var nextFreeY: CGFloat = 0
        let agents: [CGRect?] = agentStacks.enumerated().map { index, stack in
            guard let stack else { return nil }
            let y = max(sessions[index].midY - stack.height / 2, nextFreeY)
            nextFreeY = y + stack.height + agentGap
            return CGRect(origin: CGPoint(x: agentsX, y: y), size: stack)
        }
        let all = [project] + sessions + agents.compactMap { $0 }
        return Frames(project: project, sessions: sessions, agents: agents,
                      size: CGSize(width: all.map(\.maxX).max() ?? 0, height: all.map(\.maxY).max() ?? 0))
    }
}
