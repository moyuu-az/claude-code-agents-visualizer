import AgentsVisualizerCore
import SwiftUI

struct DashboardView: View {
    static let windowID = "dashboard"
    @Environment(DashboardModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let projects = model.visibleProjects
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryStrip(snapshot: model.snapshot)
                ForEach(model.snapshot.issues, id: \.self) { IssueBanner(issue: $0) }
                if !model.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if projects.isEmpty {
                    EmptyState(scope: model.scope, isSearching: !model.searchText.isEmpty)
                } else {
                    MasonryLayout(columnWidth: 400, spacing: 14) {
                        ForEach(projects) { ProjectCard(project: $0) }
                    }
                    .animation(.snappy, value: projects)
                }
            }
            .padding(20)
        }
        .background(.background)
        .frame(minWidth: 460, minHeight: 360)
        .navigationTitle("Claude Code Agents")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $model.scope) {
                    ForEach(SessionScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(Text("Which sessions to show"))
            }
            ToolbarItem {
                Button { model.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help(Text("Refresh now (updates automatically every 2 seconds)"))
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Filter sessions"))
        .alert(
            "Open in Claude?",
            isPresented: Binding(get: { model.pendingImport != nil }, set: { if !$0 { model.pendingImport = nil } }),
            presenting: model.pendingImport
        ) { session in
            Button("Open in Claude") { model.confirmImport() }
            if let command = ClaudeDeepLink.resumeCommand(for: session) {
                Button("Copy Resume Command") { model.copyToPasteboard(command) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This session was started outside Claude for Mac. Claude will import its conversation as a new desktop session.")
        }
        .alert(
            "Cannot open the session",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }
}

/// Global counters: the "how is everything going" answer before reading any card.
struct SummaryStrip: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        let agents = snapshot.allSessions.reduce(0) { $0 + $1.runningAgentCount }
        HStack(spacing: 10) {
            ForEach([SessionStatus.needsInput, .running, .idle], id: \.self) { status in
                Counter(value: snapshot.count(status), label: Text(status.label), color: status.color,
                        emphasized: status == .needsInput && snapshot.count(status) > 0)
            }
            Counter(value: agents, label: Text("Agents running"), color: .green, emphasized: false)
            Spacer(minLength: 0)
        }
    }

    private struct Counter: View {
        let value: Int
        let label: Text
        let color: Color
        let emphasized: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value, format: .number)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(value > 0 ? color : .secondary)
                    .contentTransition(.numericText())
                label
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(emphasized ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if emphasized {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(0.5))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct ProjectCard: View {
    let project: ProjectGroup

    var body: some View {
        let top = project.topStatus
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(project.sessions) { SessionRow(session: $0) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(top == .needsInput ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: top == .needsInput ? 1.5 : 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: project.name == "Scratch" ? "tray" : "folder.fill")
                .foregroundStyle(project.topStatus == .ended ? Color.secondary : project.topStatus.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: (project.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(Text(verbatim: project.path))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                ForEach([SessionStatus.needsInput, .running, .idle, .ended], id: \.self) { status in
                    let count = project.sessions.count { $0.status == status }
                    if count > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(status == .ended ? Color.secondary.opacity(0.5) : status.color)
                                .frame(width: 7, height: 7)
                            Text(count, format: .number).font(.caption.monospacedDigit())
                        }
                        .help(Text(status.label))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct IssueBanner: View {
    let issue: DashboardIssue

    var body: some View {
        Label {
            switch issue {
            case .claudeDirectoryMissing(let path):
                Text("Claude Code data was not found at \(path). Run Claude Code once, then the dashboard fills in automatically.")
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct EmptyState: View {
    let scope: SessionScope
    let isSearching: Bool

    var body: some View {
        Group {
            if isSearching {
                ContentUnavailableView.search
            } else {
                ContentUnavailableView {
                    Label(scope == .live ? "No live sessions" : "No sessions", systemImage: "moon.zzz")
                } description: {
                    Text(scope == .all
                         ? "Sessions appear here as soon as Claude Code starts."
                         : "Nothing in this time range. Choose a wider range in the toolbar to see older sessions.")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// Packs cards into equal-width columns, always placing the next card in the shortest column, so cards of
/// very different heights do not leave the gaps a grid would.
struct MasonryLayout: Layout {
    var columnWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? columnWidth
        let frames = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = max(1, Int((width + spacing) / (columnWidth + spacing)))
        let actualWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: actualWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (actualWidth + spacing), y: heights[column],
                               width: actualWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
    }
}
