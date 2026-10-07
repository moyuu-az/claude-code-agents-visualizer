import AgentsVisualizerCore
import AppKit
import SwiftUI

/// Menu bar icon: shows how many sessions need you, else how many are running.
struct MenuBarLabel: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        let needsInput = snapshot.count(.needsInput)
        let running = snapshot.count(.running)
        if needsInput > 0 {
            Label("\(needsInput)", systemImage: "exclamationmark.bubble.fill")
                .labelStyle(.titleAndIcon)
        } else if running > 0 {
            Label("\(running)", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "sparkles")
                .accessibilityLabel(Text("Claude Code Agents"))
        }
    }
}

/// Compact list of live and unread sessions, most urgent first.
struct MenuBarPanel: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let live = model.snapshot.projects.flatMap { project in
            project.sessions.filter { $0.status.isLive || $0.isUnread }.map { (project, $0) }
        }
        .sorted { SnapshotOrdering.urgentFirst($0.1, $1.1) }

        VStack(alignment: .leading, spacing: 0) {
            SummaryStrip(snapshot: model.snapshot)
                .padding(12)
            Divider()
            if live.isEmpty {
                Text("No live sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(live, id: \.1.id) { project, session in
                            Button {
                                dismiss()
                                model.open(session)
                                // The import confirmation and errors are alerts of the dashboard window, which may
                                // be closed or behind other apps; without it they never show (or show much later).
                                if model.pendingImport != nil || model.errorMessage != nil { showDashboard() }
                            } label: {
                                HStack(spacing: 8) {
                                    StatusGlyph(status: session.status, size: 11)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                                            if session.isUnread { UnreadDot() }
                                            Text(verbatim: session.title).lineLimit(1)
                                        }
                                        Text(verbatim: project.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    if session.runningAgentCount > 0 {
                                        AgentOrbit(agents: session.agents, size: 26)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(HoverRowStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Button("Open Dashboard") {
                    dismiss()
                    showDashboard()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(10)
        }
        .frame(width: 380)
    }

    private func showDashboard() {
        openWindow(id: DashboardView.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SnapshotOrdering {
    static func urgentFirst(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.status.urgency != rhs.status.urgency { return lhs.status.urgency < rhs.status.urgency }
        return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
    }
}
