import AgentsVisualizerCore
import SwiftUI

struct SessionRow: View {
    let session: SessionInfo
    @Environment(DashboardModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.open(session) } label: { content }
                .buttonStyle(HoverRowStyle())
                .help(Text("Open in Claude"))
                .contextMenu { SessionMenu(session: session) }
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text("Opens the session in Claude"))
            if !session.agents.isEmpty {
                AgentList(session: session)
            }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusGlyph(symbol: session.status.symbol, color: session.status.color, isActive: session.status == .running)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: session.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(session.status == .ended ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    RelativeTime(date: session.lastActivityAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                metadata
                if session.status == .needsInput {
                    Label {
                        Text(verbatim: session.waitingFor?.capitalizedFirst ?? String(localized: "Waiting for your response"))
                    } icon: {
                        Image(systemName: "hand.raised.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                }
                if let activity = session.activity {
                    Label { Text(verbatim: activity) } icon: { Image(systemName: "gearshape.2") }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Text(session.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(session.status.color)
            Tag(text: session.surface == .ssh && session.sshHost != nil
                    ? Text(verbatim: "SSH · \(session.sshHost!)") : Text(session.surface.label),
                symbol: session.surface.symbol)
            if let worktree = session.worktreeName {
                Tag(text: Text(verbatim: worktree), symbol: "square.stack.3d.up", tint: .purple)
                    .help(Text("Git worktree"))
            } else if let branch = session.branch {
                Tag(text: Text(verbatim: branch), symbol: "arrow.triangle.branch")
            }
            ForEach(session.pullRequests.prefix(2), id: \.url) { pr in
                Tag(text: Text(verbatim: "#\(pr.number)"), symbol: "arrow.triangle.pull", tint: pr.tint)
                    .help(Text(verbatim: pr.state.map { "\(pr.url.absoluteString) (\($0.lowercased()))" } ?? pr.url.absoluteString))
            }
            if session.runningAgentCount > 0 {
                Tag(text: Text("\(session.runningAgentCount) agents running"), symbol: "person.2.fill", tint: .green)
            }
        }
    }
}

/// Subagents of a live session, drawn as a tree under it. Finished agents collapse behind a disclosure so a
/// long-lived session does not push everything else off screen.
struct AgentList: View {
    let session: SessionInfo
    // `@State` is a compiler macro in the macOS 27 SDK whose plugin ships only with Xcode. A stored `State`
    // value is what the macro expands to, and it also builds with the Command Line Tools alone.
    private let showAllState = State(initialValue: false)
    private var showAll: Bool {
        get { showAllState.wrappedValue }
        nonmutating set { showAllState.wrappedValue = newValue }
    }
    static let collapsedFinishedLimit = 2

    private var collapsed: [AgentInfo] {
        session.agents.filter(\.status.isActive)
            + session.agents.filter { !$0.status.isActive }.prefix(Self.collapsedFinishedLimit)
    }

    var body: some View {
        let collapsed = collapsed
        let visible = showAll ? session.agents : collapsed
        let hiddenCount = session.agents.count - collapsed.count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, agent in
                AgentRow(session: session, agent: agent, isLast: index == visible.count - 1)
            }
            if hiddenCount > 0 {
                Button {
                    withAnimation(.snappy) { showAll.toggle() }
                } label: {
                    Text(showAll ? "Show fewer agents" : "Show \(hiddenCount) more agents")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .padding(.leading, 42)
                .padding(.bottom, 6)
            }
        }
        .padding(.bottom, 4)
    }
}

struct AgentRow: View {
    let session: SessionInfo
    let agent: AgentInfo
    let isLast: Bool
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button { model.open(session) } label: {
            HStack(alignment: .top, spacing: 6) {
                TreeConnector(isLast: isLast)
                StatusGlyph(symbol: agent.status.symbol, color: agent.status.color, isActive: agent.status.isActive, size: 10)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Tag(text: Text(verbatim: agent.agentType), symbol: agent.isBackground ? "moon.stars" : "person.fill",
                            tint: agent.status.isActive ? .green : .secondary)
                        Text(verbatim: agent.description)
                            .font(.caption)
                            .foregroundStyle(agent.status.isActive ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if agent.status.isActive {
                            RelativeTime(date: agent.startedAt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(agent.status.label)
                                .font(.caption2)
                                .foregroundStyle(agent.status.color)
                        }
                    }
                    if let activity = agent.activity {
                        Text(verbatim: activity)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.vertical, 2)
        }
        .buttonStyle(HoverRowStyle())
        .help(Text("Open the parent session in Claude"))
        .accessibilityElement(children: .combine)
    }
}

/// "├" / "└" connector linking an agent to its session.
private struct TreeConnector: View {
    let isLast: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let x = size.width / 2
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: isLast ? size.height / 2 : size.height))
            path.move(to: CGPoint(x: x, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        }
        .frame(width: 12, height: 18)
        .accessibilityHidden(true)
    }
}

struct SessionMenu: View {
    let session: SessionInfo
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button("Open in Claude") { model.open(session) }
        Divider()
        if let command = ClaudeDeepLink.resumeCommand(for: session) {
            Button("Copy Resume Command") { model.copyToPasteboard(command) }
        }
        Button("Copy Session ID") { model.copyToPasteboard(session.id) }
        Divider()
        Button("Open Folder in Finder") { model.revealInFinder(path: session.cwd) }
        if let transcript = session.transcriptPath {
            Button("Reveal Transcript in Finder") { model.revealInFinder(path: transcript) }
        }
        if !session.pullRequests.isEmpty {
            Divider()
            ForEach(session.pullRequests, id: \.url) { pr in
                Link(destination: pr.url) { Text("Open Pull Request #\(pr.number)") }
            }
        }
    }
}

struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        private let hoveringState = State(initialValue: false)  // see AgentList for why not `@State`

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.10 : hoveringState.wrappedValue ? 0.05 : 0),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hoveringState.wrappedValue = $0 }
        }
    }
}

extension PullRequestRef {
    var tint: Color {
        switch state?.uppercased() {
        case "MERGED": .purple
        case "CLOSED": .red
        default: .green
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
