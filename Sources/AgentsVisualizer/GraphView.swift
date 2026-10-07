import AgentsVisualizerCore
import SwiftUI

/// The "graph" page: projects → sessions → agents as a living network, with an activity log underneath.
struct GraphPage: View {
    let snapshot: DashboardSnapshot
    let projects: [ProjectGroup]
    let events: [ActivityEvent]
    let scope: SessionScope
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 12) {
                        SummaryStrip(snapshot: snapshot)
                        AgentLegend(snapshot: snapshot)
                    }
                    if projects.isEmpty {
                        EmptyState(scope: scope, isSearching: isFiltered)
                    } else {
                        // Same shared clock as the dashboard, so relative times tick together.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            GraphCanvas(projects: DashboardFilter.stableOrder(projects))
                                .environment(\.dashboardClock, context.date)
                        }
                    }
                }
                .padding(20)
                .frame(minWidth: 940, alignment: .leading)
            }
            ActivityLog(events: events)
                .padding([.horizontal, .bottom], 16)
        }
    }
}

// MARK: - Layout

private enum GraphNode: Hashable {
    case project(String)
    case session(String)
    case agent(session: String, agent: String)
    case more(session: String)
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

/// Per project: the project node, its sessions in two staggered columns (`GraphRowLayout`) and each session's agents.
/// Nodes report their frames through anchor preferences; the edges are drawn behind them from those frames.
private struct GraphCanvas: View {
    let projects: [ProjectGroup]
    // `@State` is a compiler macro in the macOS 27 SDK (see AgentList); a stored `State` value builds everywhere.
    private let expandedState = State(initialValue: Set<String>())

    static let geometry = GraphRowLayout(projectWidth: 210, session: CGSize(width: 260, height: 104), columnGap: 56,
                                         zigzagGap: 20, rowGap: 12, agentGap: 14)
    static let finishedShown = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
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
                        let (visible, hidden) = agentsToShow(session)
                        if !visible.isEmpty || hidden > 0 {
                            agentStack(session, visible: visible, hidden: hidden)
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

    private func agentStack(_ session: SessionInfo, visible: [AgentInfo], hidden: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visible) { agent in
                AgentNode(session: session, agent: agent)
                    .graphNode(.agent(session: session.id, agent: agent.id))
                    .transition(.opacity)
            }
            if hidden > 0 {
                MoreAgentsChip(count: hidden, expanded: expandedState.wrappedValue.contains(session.id)) {
                    expandedState.wrappedValue.formSymmetricDifference([session.id])
                }
                .graphNode(.more(session: session.id))
            }
        }
    }

    /// Running agents always; finished ones only the latest few unless the user expands the session.
    private func agentsToShow(_ session: SessionInfo) -> (visible: [AgentInfo], hidden: Int) {
        let running = session.agents.filter(\.status.isActive)
        let finished = session.agents.filter { !$0.status.isActive }
        if expandedState.wrappedValue.contains(session.id) { return (running + finished, finished.count > Self.finishedShown ? 1 : 0) }
        let shown = Array(finished.prefix(Self.finishedShown))
        return (running + shown, finished.count - shown.count)
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
    /// second, both at the session's height, which `GraphRowLayout` keeps clear of cards.
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
                for agent in session.agents {
                    guard let agentFrame = frames[.agent(session: session.id, agent: agent.id)] else { continue }
                    edges.append(GraphEdge(
                        id: "a-\(session.id)-\(agent.id)", from: sessionFrame.trailingCenter, to: agentFrame.leadingCenter,
                        bend: (agentFrame.minX - gap)...agentFrame.minX,
                        color: agent.typeColor, flow: agent.status.isActive ? .active : .faded))
                }
                if let moreFrame = frames[.more(session: session.id)] {
                    edges.append(GraphEdge(id: "m-\(session.id)", from: sessionFrame.trailingCenter,
                                           to: moreFrame.leadingCenter, bend: (moreFrame.minX - gap)...moreFrame.minX,
                                           color: .secondary, flow: .faded))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    if busy { SpinnerRing(color: .green, lineWidth: 2, showsTrack: false, showsCore: false, period: 2.4) }
                    Image(systemName: project.name == "Scratch" ? "tray.fill" : "folder.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(top == .ended ? Color.secondary : top.color)
                }
                .frame(width: 34, height: 34)
                .glassSurface(Circle(), tint: top == .ended ? nil : top.color.opacity(0.22))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: project.name).font(.headline).lineLimit(1)
                    Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 10) {
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
        }
        .padding(14)
        .frame(width: GraphCanvas.geometry.projectWidth, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous),
                      tint: top == .needsInput ? Color.orange.opacity(0.14) : nil)
        .help(Text(verbatim: project.path))
    }
}

private struct SessionNode: View {
    let session: SessionInfo
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button { model.open(session) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    StatusGlyph(status: session.status)
                    Text(verbatim: session.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(session.status == .ended ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    RelativeTime(date: session.lastActivityAt).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Text(session.status.label).font(.caption2.weight(.bold)).foregroundStyle(session.status.color)
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
            .padding(12)
            // Fixed size, set by GraphCanvas: a card that grew with its status would push the whole graph around.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                switch session.status {
                case .needsInput: BreathingFill(color: Color.orange.opacity(0.22), cornerRadius: 18)
                case .running: BreathingFill(color: Color.green.opacity(0.10), cornerRadius: 18)
                case .idle, .ended: EmptyView()
                }
            }
            .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: tint, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text("Open in Claude"))
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

private struct AgentNode: View {
    let session: SessionInfo
    let agent: AgentInfo
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button { model.open(session) } label: {
            HStack(alignment: .center, spacing: 9) {
                AgentAvatar(agent: agent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: agent.agentType)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(agent.status.isActive ? agent.typeColor : .secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let model = ModelName.display(agent.model) {
                            Text(verbatim: model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if agent.status.isActive, let startedAt = agent.startedAt {
                            Text(timerInterval: min(startedAt, .distantFuture)...Date.distantFuture, countsDown: false)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(agent.typeColor)
                                .frame(minWidth: 32, alignment: .trailing)
                        } else if !agent.status.isActive {
                            HStack(spacing: 3) {
                                AgentStatusMark(status: agent.status)
                                Text(agent.status.label).font(.caption2).foregroundStyle(agent.status.color)
                            }
                            .fixedSize()  // the model name truncates first, never the status
                        }
                    }
                    Text(verbatim: agent.description)
                        .font(.caption)
                        .foregroundStyle(agent.status.isActive ? .primary : .secondary)
                        .lineLimit(1)
                    if let activity = agent.activity {
                        ShimmerText(text: activity)
                            .accessibilityRepresentation { Text(verbatim: activity) }
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(width: 250, alignment: .leading)
            .background {
                if agent.status.isActive { BreathingFill(color: agent.typeColor.opacity(0.16), cornerRadius: 14) }
            }
            .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous),
                          tint: agent.status.isActive ? agent.typeColor.opacity(0.14) : nil, interactive: true)
            .opacity(agent.status.isActive ? 1 : 0.72)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text("Open the parent session in Claude"))
    }
}

private struct MoreAgentsChip: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: { withAnimation(.snappy) { toggle() } }) {
            Label {
                if expanded { Text("Hide finished agents") } else { Text("Show finished agents (\(count))") }
            } icon: {
                Image(systemName: expanded ? "chevron.up" : "ellipsis")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassSurface(Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 6) {
            Label("Activity", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if events.isEmpty {
                Text("Events appear here as sessions and agents start, finish or need you.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(events.prefix(Self.visibleCount)) { event in
                        ActivityRow(event: event)
                            .transition(.push(from: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: events.prefix(Self.visibleCount).map(\.id))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
