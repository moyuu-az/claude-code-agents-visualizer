import AgentsVisualizerCore
import SwiftUI

/// The "graph" page: projects → sessions → agents as a living network, with an activity log underneath.
struct GraphPage: View {
    let snapshot: DashboardSnapshot
    let projects: [ProjectGroup]
    let events: [ActivityEvent]
    let scope: SessionScope
    let isFiltered: Bool

    static let padding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            SummaryStrip(snapshot: snapshot)
                            AgentLegend(snapshot: snapshot)
                        }
                        if projects.isEmpty {
                            EmptyState(scope: scope, isSearching: isFiltered)
                        } else {
                            // Same shared clock as the dashboard, so relative times tick together.
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                // 16 more for a legacy (always shown) vertical scroller, which takes its width from
                                // the viewport; without it the last agent column would scroll sideways.
                                GraphCanvas(projects: DashboardFilter.stableOrder(projects),
                                            agentColumns: GraphCanvas.geometry.agentColumns(
                                                width: viewport.size.width - Self.padding * 2 - 16))
                                    .environment(\.dashboardClock, context.date)
                            }
                        }
                    }
                    .padding(Self.padding)
                    .frame(minWidth: 940, alignment: .leading)
                }
            }
            ActivityLog(events: events)
                .padding([.horizontal, .bottom], 12)
        }
    }
}

// MARK: - Layout

private enum GraphNode: Hashable {
    case project(String)
    case session(String)
    case agent(session: String, agent: String)
}

private struct NodeAnchors: PreferenceKey {
    static var defaultValue: [GraphNode: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [GraphNode: Anchor<CGRect>], nextValue: () -> [GraphNode: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func graphNode(_ node: GraphNode) -> some View {
        anchorPreference(key: NodeAnchors.self, value: .bounds) { [node: $0] }
    }
}

/// Per project: the project node, its sessions in two staggered columns (`GraphRowLayout`) and each session's agents
/// in lines of `agentColumns`. Nodes report their frames through anchor preferences; the edges are drawn behind them
/// from those frames.
private struct GraphCanvas: View {
    let projects: [ProjectGroup]
    let agentColumns: Int
    // `@State` is a compiler macro in the macOS 27 SDK (see AgentList); a stored `State` value builds everywhere.
    private let expandedState = State(initialValue: Set<String>())

    static let geometry = GraphRowLayout.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(projects) { project in
                GraphRow(geometry: Self.geometry) {
                    ProjectNode(project: project)
                        .graphNode(.project(project.id))
                        .layoutValue(key: GraphSlot.self, value: .project)
                    ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionNode(session: session)
                            .frame(width: Self.geometry.session.width, height: Self.geometry.session.height)
                            .graphNode(.session(session.id))
                            .layoutValue(key: GraphSlot.self, value: .session(index))
                        let (shown, overflow) = agentsToShow(session)
                        if !shown.isEmpty {
                            agentLines(session, shown: shown, overflow: overflow)
                                .layoutValue(key: GraphSlot.self, value: .agents(index))
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
        }
        .backgroundPreferenceValue(NodeAnchors.self) { anchors in
            GeometryReader { proxy in
                GraphEdgesView(edges: edges(anchors.mapValues { proxy[$0] }))
            }
        }
        // No bounce: overshooting nodes are exactly the kind of motion that makes the graph hard to follow.
        .animation(.smooth(duration: 0.45), value: structure)
    }

    /// `shown` in lines of `agentColumns`, the toggle for the `overflow` at the end of the last line, where
    /// `agentColumns` leaves room for it.
    private func agentLines(_ session: SessionInfo, shown: [AgentInfo], overflow: Int) -> some View {
        let gap = Self.geometry.agentGap
        let lines = GraphRowLayout.lines(shown, columns: agentColumns)
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(lines.indices, id: \.self) { line in
                HStack(spacing: gap) {
                    ForEach(lines[line]) { agent in
                        AgentNode(session: session, agent: agent)
                            .graphNode(.agent(session: session.id, agent: agent.id))
                            .transition(.opacity)
                    }
                    if overflow > 0, line == lines.count - 1 {
                        MoreAgentsToggle(count: overflow, expanded: expandedState.wrappedValue.contains(session.id)) {
                            expandedState.wrappedValue.formSymmetricDifference([session.id])
                        }
                    }
                }
            }
        }
    }

    private func agentsToShow(_ session: SessionInfo) -> (shown: [AgentInfo], overflow: Int) {
        GraphRowLayout.agentsToShow(session.agents, columns: agentColumns,
                                    expanded: expandedState.wrappedValue.contains(session.id))
    }

    /// What changes the drawing's shape; timestamps and activity text deliberately excluded so routine refreshes do
    /// not animate the whole graph.
    private var structure: [String] {
        projects.flatMap { project in
            [project.id] + project.sessions.flatMap { session in
                ["\(session.id):\(session.status)"] + session.agents.map { "\($0.id):\($0.status)" }
            }
        }
    }

    /// Edges bend only in the gap right after the project or right before the agents, and run straight elsewhere: an
    /// edge to a second-column session crosses the first column, and one from a first-column session crosses the
    /// second, both at the session's height, which `GraphRowLayout` keeps clear of cards. Only the first agent of each
    /// line gets an edge: one to the next would run under its neighbour. Running agents come first, so that edge
    /// flows whenever any agent of its line runs.
    private func edges(_ frames: [GraphNode: CGRect]) -> [GraphEdge] {
        let gap = Self.geometry.columnGap
        var edges: [GraphEdge] = []
        for project in projects {
            guard let projectFrame = frames[.project(project.id)] else { continue }
            let toSessions = projectFrame.maxX...(projectFrame.maxX + gap)
            for session in project.sessions {
                guard let sessionFrame = frames[.session(session.id)] else { continue }
                edges.append(GraphEdge(
                    id: "p-\(session.id)", from: projectFrame.trailingCenter, to: sessionFrame.leadingCenter,
                    bend: toSessions, color: session.status == .ended ? .secondary : session.status.color,
                    flow: Self.flow(for: session.status)))
                for agent in GraphRowLayout.lines(agentsToShow(session).shown, columns: agentColumns).compactMap(\.first) {
                    guard let agentFrame = frames[.agent(session: session.id, agent: agent.id)] else { continue }
                    edges.append(GraphEdge(
                        id: "a-\(session.id)-\(agent.id)", from: sessionFrame.trailingCenter, to: agentFrame.leadingCenter,
                        bend: (agentFrame.minX - gap)...agentFrame.minX,
                        color: agent.typeColor, flow: agent.status.isActive ? .active : .faded))
                }
            }
        }
        return edges
    }

    private static func flow(for status: SessionStatus) -> GraphEdge.Flow {
        switch status {
        case .running, .needsInput: .active
        case .idle: .resting
        case .ended: .faded
        }
    }
}

private extension CGRect {
    var leadingCenter: CGPoint { CGPoint(x: minX, y: midY) }
    var trailingCenter: CGPoint { CGPoint(x: maxX, y: midY) }
}

private enum GraphRowSlot {
    case project, session(Int), agents(Int)
}

private struct GraphSlot: LayoutValueKey {
    static let defaultValue = GraphRowSlot.project
}

/// Places one project's nodes, each tagged with its `GraphSlot`, at the frames `GraphRowLayout` computes.
private struct GraphRow: Layout {
    let geometry: GraphRowLayout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(subviews)
        for subview in subviews {
            let frame: CGRect? = switch subview[GraphSlot.self] {
            case .project: frames.project
            case .session(let index): frames.sessions[index]
            case .agents(let index): frames.agents[index]
            }
            guard let frame else { continue }
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ subviews: Subviews) -> GraphRowLayout.Frames {
        var projectHeight: CGFloat = 0
        var sessionCount = 0
        var stacks: [Int: CGSize] = [:]
        for subview in subviews {
            switch subview[GraphSlot.self] {
            case .project: projectHeight = subview.sizeThatFits(.unspecified).height
            case .session(let index): sessionCount = max(sessionCount, index + 1)
            case .agents(let index): stacks[index] = subview.sizeThatFits(.unspecified)
            }
        }
        return geometry.frames(projectHeight: projectHeight, agentStacks: (0..<sessionCount).map { stacks[$0] })
    }
}

// MARK: - Nodes

private struct ProjectNode: View {
    let project: ProjectGroup

    var body: some View {
        let top = project.topStatus
        let busy = project.sessions.contains { $0.status == .running }
        VStack(alignment: .leading, spacing: 5) {
            // The icon shares its row with the counts, so the name gets the node's full width: the column is narrow
            // and repository names are long.
            HStack(spacing: 8) {
                ZStack {
                    if busy { SpinnerRing(color: .green, lineWidth: 2, showsTrack: false, showsCore: false, period: 2.4) }
                    Image(systemName: project.name == "Scratch" ? "tray.fill" : "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(top == .ended ? Color.secondary : top.color)
                }
                .frame(width: 28, height: 28)
                .glassSurface(Circle(), tint: top == .ended ? nil : top.color.opacity(0.22))
                ForEach([SessionStatus.needsInput, .running, .idle, .ended], id: \.self) { status in
                    let count = project.sessions.count { $0.status == status }
                    if count > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(status == .ended ? Color.secondary.opacity(0.5) : status.color).frame(width: 6, height: 6)
                            Text(count, format: .number).font(.caption2.monospacedDigit())
                        }
                        .help(Text(status.label))
                    }
                }
                let agents = project.sessions.reduce(0) { $0 + $1.runningAgentCount }
                if agents > 0 {
                    Label("\(agents)", systemImage: "person.2.fill").font(.caption2).foregroundStyle(.teal)
                }
            }
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: project.name).lineLimit(1)
                    Text(verbatim: GraphRowLayout.twoLineName(project.name)).lineLimit(2)
                }
                .font(.headline)
                Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(width: GraphCanvas.geometry.projectWidth, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous),
                      tint: top == .needsInput ? Color.orange.opacity(0.14) : nil)
        .help(Text(verbatim: project.path))
    }
}

private struct SessionNode: View {
    let session: SessionInfo
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button { model.open(session) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    StatusGlyph(status: session.status, size: 12)
                    // Unread sessions show in every time range; without the dot an ended one would look misplaced.
                    if session.isUnread { UnreadDot().padding(.top, 3) }
                    Text(verbatim: session.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(session.status == .ended ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 2)
                    RelativeTime(date: session.lastActivityAt).font(.caption2).foregroundStyle(.secondary)
                }
                // No status label: the glyph and the card's tint already say it, and the tags need the width.
                HStack(spacing: 4) {
                    if let model = ModelName.display(session.model) {
                        Tag(text: Text(verbatim: [model, session.effort].compactMap { $0 }.joined(separator: " · ")),
                            symbol: "sparkle", tint: .indigo)
                    }
                    if let worktree = session.worktreeName {
                        Tag(text: Text(verbatim: worktree), symbol: "square.stack.3d.up", tint: .purple)
                    } else {
                        Tag(text: Text(session.surface.label), symbol: session.surface.symbol)
                    }
                }
                if session.status == .needsInput {
                    Label {
                        Text(verbatim: SessionRow.waitingDescription(session.waitingFor)).lineLimit(1)
                    } icon: {
                        AnimatedSymbol(systemName: "hand.raised.fill", color: .orange, pointSize: 10, motion: .wiggle)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                } else if let activity = session.activity {
                    ShimmerText(text: activity, shimmers: false)
                        .accessibilityRepresentation { Text(verbatim: activity) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // Fixed size, set by GraphCanvas: a card that grew with its status would push the whole graph around.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                switch session.status {
                case .needsInput: BreathingFill(color: Color.orange.opacity(0.22), cornerRadius: 14)
                case .running: BreathingFill(color: Color.green.opacity(0.10), cornerRadius: 14)
                case .idle, .ended: EmptyView()
                }
            }
            .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: tint, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: session.title + "\n") + Text(session.status.label) + Text(verbatim: " · ") + Text("Open in Claude"))
        .accessibilityValue(Text(session.status.label))
        .contextMenu { SessionMenu(session: session) }
    }

    private var tint: Color? {
        switch session.status {
        case .needsInput: .orange.opacity(0.16)
        case .running: .green.opacity(0.10)
        case .idle, .ended: nil
        }
    }
}

/// One agent at `GraphRowLayout.agent` size: what it was asked to do on top, its type and model (or, while it runs,
/// what it is doing right now) underneath, and its timer or final state on the right.
private struct AgentNode: View {
    let session: SessionInfo
    let agent: AgentInfo
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button { model.open(session) } label: {
            HStack(alignment: .center, spacing: 7) {
                AgentAvatar(agent: agent, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(verbatim: agent.description)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(agent.status.isActive ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if agent.status.isActive, let startedAt = agent.startedAt {
                            Text(timerInterval: min(startedAt, .distantFuture)...Date.distantFuture, countsDown: false)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(agent.typeColor)
                                .fixedSize()
                        } else if !agent.status.isActive {
                            AgentStatusMark(status: agent.status)
                        }
                    }
                    HStack(spacing: 4) {
                        // Priority, not fixedSize: plugin agent types (`pr-review-toolkit:silent-failure-hunter`) are
                        // wider than the card and would draw over the next card in the line.
                        Text(verbatim: agent.agentType)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(agent.status.isActive ? agent.typeColor : .secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        // Kept while the agent runs, empty between tool calls, like the card's size: a line that came
                        // and went with every tool call would flicker the model name in and out.
                        if agent.status.isActive {
                            ShimmerText(text: agent.activity ?? "")
                                .accessibilityRepresentation { Text(verbatim: agent.activity ?? "") }
                                .accessibilityHidden(agent.activity == nil)
                        } else if let model = ModelName.display(agent.model) {
                            Text(verbatim: model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(width: GraphCanvas.geometry.agent.width, height: GraphCanvas.geometry.agent.height, alignment: .leading)
            .background {
                if agent.status.isActive { BreathingFill(color: agent.typeColor.opacity(0.16), cornerRadius: 11) }
            }
            .glassSurface(RoundedRectangle(cornerRadius: 11, style: .continuous),
                          tint: agent.status.isActive ? agent.typeColor.opacity(0.14) : nil, interactive: true)
            .opacity(agent.status.isActive ? 1 : 0.72)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        // The card truncates the description; the tooltip has all of it and the final state in words.
        .help(Text(verbatim: "\(agent.agentType): \(agent.description)\n") + Text(agent.status.label) + Text(verbatim: " · ")
              + Text("Open the parent session in Claude"))
        .accessibilityValue(Text(agent.status.label))
    }
}

/// "+n" at the end of a session's agent line for the finished agents that did not fit; a chevron to fold them back.
private struct MoreAgentsToggle: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let label = expanded ? Text("Hide finished agents") : Text("Show finished agents (\(count))")
        Button(action: { withAnimation(.snappy) { toggle() } }) {
            Group {
                if expanded { Image(systemName: "chevron.up") } else { Text(verbatim: "+\(count)") }
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .frame(width: GraphCanvas.geometry.toggleWidth, height: GraphCanvas.geometry.agent.height)
            .glassSurface(RoundedRectangle(cornerRadius: 11, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Colour key for the agent types currently on screen.
private struct AgentLegend: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        let agents = snapshot.allSessions.flatMap(\.agents)
        let types = Dictionary(agents.map { ($0.agentType, $0) }, uniquingKeysWith: { first, _ in first })
            .sorted { $0.key < $1.key }
            .prefix(6)
        if !types.isEmpty {
            GlassGroup(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(types, id: \.key) { type, agent in
                        HStack(spacing: 5) {
                            Image(systemName: agent.typeSymbol).font(.caption2).foregroundStyle(agent.typeColor)
                            Text(verbatim: type).font(.caption)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .glassSurface(Capsule(), tint: agent.typeColor.opacity(0.12))
                    }
                }
            }
        }
    }
}

// MARK: - Activity log

/// Live feed of what changed: agents spawning and finishing, sessions starting, finishing turns, needing you.
private struct ActivityLog: View {
    let events: [ActivityEvent]
    static let visibleCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Activity", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if events.isEmpty {
                Text("Events appear here as sessions and agents start, finish or need you.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(events.prefix(Self.visibleCount)) { event in
                        ActivityRow(event: event)
                            .transition(.push(from: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: events.prefix(Self.visibleCount).map(\.id))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(event.at, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(verbatim: event.projectName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            message
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var message: some View {
        let session = event.sessionTitle
        let agent = event.agentType ?? ""
        let task = event.agentDescription ?? ""
        switch event.kind {
        case .sessionStarted: Text("\(session) started")
        case .turnStarted: Text("\(session) is working")
        case .needsInput: Text("\(session) needs your input").foregroundStyle(.orange)
        case .turnFinished: Text("\(session) finished its turn")
        case .sessionEnded: Text("\(session) ended").foregroundStyle(.secondary)
        case .agentSpawned: Text("\(agent) started: \(task)")
        case .agentFinished(let status):
            switch status {
            case .completed: Text("\(agent) completed: \(task)")
            case .failed: Text("\(agent) failed: \(task)").foregroundStyle(.red)
            case .stopped, .interrupted: Text("\(agent) stopped: \(task)").foregroundStyle(.secondary)
            case .running: Text("\(agent) started: \(task)")
            }
        }
    }

    private var symbol: String {
        switch event.kind {
        case .sessionStarted: "play.circle.fill"
        case .turnStarted: "bolt.fill"
        case .needsInput: "exclamationmark.bubble.fill"
        case .turnFinished: "checkmark.circle.fill"
        case .sessionEnded: "stop.circle"
        case .agentSpawned: "arrow.triangle.branch"
        case .agentFinished(let status): status.symbol
        }
    }

    private var color: Color {
        switch event.kind {
        case .sessionStarted, .turnStarted: .green
        case .needsInput: .orange
        case .turnFinished: .blue
        case .sessionEnded: .secondary
        case .agentSpawned: .teal
        case .agentFinished(let status): status == .completed ? .green : status.color
        }
    }
}
