import CoreGraphics

/// Geometry of one project on the graph page: the project node, its sessions in two staggered columns, and each
/// session's agents in lines to their right.
///
/// The second session column sits half a row lower than the first, so every session's centre lines up with the gap
/// between two cards of the other column. Edges run straight through those gaps instead of under cards, and n sessions
/// take about n/2 rows instead of n. That only holds while every session card is exactly `session` sized.
///
/// Agents fill lines across the width the window leaves right of the sessions instead of stacking in one column, and
/// one line of them is no taller than the half row each session has. A project is then as tall as its sessions,
/// however many agents they have, unless a session has more running agents than one line holds.
public struct GraphRowLayout: Sendable {
    public var projectWidth: CGFloat
    public var session: CGSize
    /// Every agent card has this size, so a line of them is exactly `agent.height` tall.
    public var agent: CGSize
    /// Between the project and the sessions, and between the sessions and the agents.
    public var columnGap: CGFloat
    /// Between the two session columns.
    public var zigzagGap: CGFloat
    /// Between two cards of one session column; edges from the other column pass through it.
    public var rowGap: CGFloat
    /// Between agent cards in a line, between the lines of one session, and between the agents of consecutive
    /// sessions.
    public var agentGap: CGFloat
    /// The "+n" toggle at the end of a session's agent line; `agentColumns` always leaves room for it.
    public var toggleWidth: CGFloat

    public init(projectWidth: CGFloat, session: CGSize, agent: CGSize, columnGap: CGFloat, zigzagGap: CGFloat,
                rowGap: CGFloat, agentGap: CGFloat, toggleWidth: CGFloat) {
        self.projectWidth = projectWidth
        self.session = session
        self.agent = agent
        self.columnGap = columnGap
        self.zigzagGap = zigzagGap
        self.rowGap = rowGap
        self.agentGap = agentGap
        self.toggleWidth = toggleWidth
    }

    /// The graph page's geometry. `agent.height + agentGap` must stay within half a session row
    /// (`(session.height + rowGap) / 2`), or every session's agent line pushes the next one down and a project with
    /// many agents grows tall again.
    public static let standard = GraphRowLayout(
        projectWidth: 176, session: CGSize(width: 250, height: 80), agent: CGSize(width: 232, height: 36),
        columnGap: 40, zigzagGap: 14, rowGap: 10, agentGap: 6, toggleWidth: 40)

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

    /// Agent cards per line on a graph `width` wide: as many as fit right of the sessions next to the toggle, and at
    /// least one, so a narrow window scrolls sideways instead of hiding agents.
    public func agentColumns(width: CGFloat) -> Int {
        let fitting = (width - agentsX - toggleWidth) / (agent.width + agentGap)
        // ponytail: 64 is just a bound for Int(); no screen is that wide.
        return fitting.isFinite ? Int(min(max(fitting.rounded(.down), 1), 64)) : 1
    }

    /// `agentStacks[i]` is the size of session i's agent lines, `nil` when it has none.
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
        // never start above the top of the row: centring a tall one higher would move every session of the project
        // each time an agent starts or finishes.
        // ponytail: greedy, so one tall stack pushes every later one below its session; only sessions with more
        // running agents than a line holds (or expanded ones) are taller than their half row. Balance the drift up and
        // down if graphs with many such sessions look skewed.
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

    /// Running agents always; finished ones only as many as fill the rest of the first line of `columns`, unless
    /// `expanded`. `overflow` is how many finished agents the collapsed line leaves out, in both states, so the toggle
    /// for them stays on screen while they are shown.
    public static func agentsToShow(_ agents: [AgentInfo], columns: Int, expanded: Bool) -> (shown: [AgentInfo], overflow: Int) {
        let running = agents.filter(\.status.isActive)
        let finished = agents.filter { !$0.status.isActive }
        let room = max(max(columns, 1) - running.count, 0)
        let overflow = max(finished.count - room, 0)
        return (running + (expanded ? finished : Array(finished.prefix(room))), overflow)
    }

    /// `shown` in lines of `columns` (at least one per line). The view lays the cards out this way and draws an edge
    /// to the first of each line, so both must split the same way.
    public static func lines(_ shown: [AgentInfo], columns: Int) -> [[AgentInfo]] {
        let columns = max(columns, 1)
        return stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
    }

    /// `name` broken after the separator nearest its middle, for a project node too narrow for it on one line. Left
    /// to itself, the Japanese line breaker splits `claude-code-agents-visualizer` inside a word, even with zero-width
    /// spaces after the hyphens. A leading separator (`.dotfiles`, `_scratch`) is not a break: it would sit alone on
    /// the first line.
    public static func twoLineName(_ name: String) -> String {
        let breaks = name.indices.dropFirst().filter { "-_. ".contains(name[$0]) }.map { name.index(after: $0) }
        let middle = name.count / 2
        func distance(_ index: String.Index) -> Int { abs(name.distance(from: name.startIndex, to: index) - middle) }
        guard let at = breaks.min(by: { distance($0) < distance($1) }), at < name.endIndex else { return name }
        return name[..<at] + "\n" + name[at...]
    }
}
