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
        .background {
            if session.status == .needsInput { NeedsInputGlow() }
        }
        .animation(.snappy, value: session.status)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusGlyph(status: session.status)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    if session.isUnread {
                        UnreadDot().transition(.scale.combined(with: .opacity))
                    }
                    Text(verbatim: session.title)
                        .font(.body.weight(.semibold))
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
                        Text(verbatim: Self.waitingDescription(session.waitingFor))
                    } icon: {
                        AnimatedSymbol(systemName: "hand.raised.fill", color: .orange, pointSize: 10, motion: .wiggle)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .transition(.blurReplace)
                }
                if let activity = session.activity {
                    Label {
                        // Changes on nearly every refresh; ShimmerText animates the change in Core Animation.
                        ShimmerText(text: activity, shimmers: false)
                            .accessibilityRepresentation { Text(verbatim: activity) }
                    } icon: {
                        Image(systemName: "gearshape.2")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.push(from: .bottom).combined(with: .opacity))
                }
            }
            if session.runningAgentCount > 0 {
                AgentOrbit(agents: session.agents)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    /// Claude Code reports why it waits as a short English phrase; the common ones get a translated sentence.
    static func waitingDescription(_ reason: String?) -> String {
        switch reason {
        case "permission prompt": String(localized: "Waiting for permission")
        case "input needed": String(localized: "Waiting for your answer")
        case "worker request", "sandbox request": String(localized: "Waiting for approval")
        case "dialog open": String(localized: "A dialog is open")
        case let reason?: reason.capitalizedFirst
        case nil: String(localized: "Waiting for your response")
        }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Text(session.status.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(session.status.color)
                .contentTransition(.interpolate)
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
        }
    }
}

/// Claude for Mac's sidebar dot: the session finished with a reply you have not opened yet.
struct UnreadDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(.tint)
            .help(Text("Unread: opening the session in Claude marks it as read"))
            .accessibilityLabel(Text("Unread"))
    }
}

/// Soft orange breathing behind a session that is blocked on the user.
private struct NeedsInputGlow: View {
    var body: some View {
        BreathingFill(color: Color.orange.opacity(0.18)).padding(.horizontal, 4)
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

    /// Finished agents shown before "Show more": a few while the session works, none once it is idle.
    private var finishedLimit: Int { session.status == .running || session.status == .needsInput ? 2 : 0 }

    private var collapsed: [AgentInfo] {
        session.agents.filter(\.status.isActive)
            + session.agents.filter { !$0.status.isActive }.prefix(finishedLimit)
    }

    var body: some View {
        let collapsed = collapsed
        let visible = showAll ? session.agents : collapsed
        let hiddenCount = session.agents.count - collapsed.count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, agent in
                AgentRow(session: session, agent: agent, isLast: index == visible.count - 1 && hiddenCount == 0)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity).combined(with: .offset(x: -16)),
                        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading))))
            }
            if hiddenCount > 0 {
                HStack(spacing: 0) {
                    TreeConnector(isLast: true, isFlowing: false).frame(height: 18)
                    Button {
                        withAnimation(.snappy) { showAll.toggle() }
                    } label: {
                        Group {
                            if showAll {
                                Text("Hide finished agents")
                            } else if collapsed.isEmpty {
                                Text("Show finished agents (\(hiddenCount))")
                            } else {
                                Text("Show more agents (\(hiddenCount))")
                            }
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    .padding(.leading, 6)
                }
                .padding(.leading, 18)
            }
        }
        .padding(.bottom, 6)
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: visible.map(\.layoutKey))
    }
}

struct AgentRow: View {
    let session: SessionInfo
    let agent: AgentInfo
    let isLast: Bool
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Button { model.open(session) } label: {
            HStack(alignment: .center, spacing: 7) {
                TreeConnector(isLast: isLast, isFlowing: agent.status.isActive, color: agent.typeColor)
                AgentAvatar(agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: agent.agentType)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(agent.status.isActive ? agent.typeColor : .secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(verbatim: agent.description)
                            .font(.caption)
                            .foregroundStyle(agent.status.isActive ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        trailing
                    }
                    if let activity = agent.activity {
                        ShimmerText(text: activity)
                            .accessibilityRepresentation { Text(verbatim: activity) }
                            .transition(.push(from: .bottom).combined(with: .opacity))
                    }
                }
            }
            // Puts the connector's trunk right under the session's status glyph.
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(minHeight: 26)
        }
        .buttonStyle(HoverRowStyle())
        .help(Text("Open the parent session in Claude"))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        if agent.status.isActive, let startedAt = agent.startedAt {
            // Live stopwatch: SwiftUI updates it without re-rendering the row. `startedAt` comes from a transcript,
            // and a date past `distantFuture` would trap the range and crash on every refresh.
            Text(timerInterval: min(startedAt, .distantFuture)...Date.distantFuture, countsDown: false)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(agent.typeColor)
                .frame(minWidth: 34, alignment: .trailing)
        } else if !agent.status.isActive {
            HStack(spacing: 3) {
                AgentStatusMark(status: agent.status)
                Text(agent.status.label)
                    .font(.caption2)
                    .foregroundStyle(agent.status.color)
            }
        }
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
        if let folder = session.localCwd {
            Button("Open Folder in Finder") { model.revealInFinder(path: folder) }
        }
        // SSH sessions too: their transcript is Claude for Mac's local mirror under `~/.claude/projects/`.
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
                    Color.primary.opacity(configuration.isPressed ? 0.10 : hoveringState.wrappedValue ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 4)
                .animation(.easeOut(duration: 0.15), value: hoveringState.wrappedValue)
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
