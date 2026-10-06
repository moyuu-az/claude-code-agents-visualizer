import AgentsVisualizerCore
import AppKit
import Observation
import SwiftUI

extension SessionScope {
    var label: LocalizedStringKey {
        switch self {
        case .live: "Live"
        case .day: "24 hours"
        case .week: "7 days"
        case .all: "All"
        }
    }
}

enum DashboardPage: String, CaseIterable, Identifiable {
    case dashboard, graph

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .graph: "Graph"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .graph: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Owns the non-Sendable snapshot builder and runs its file I/O off the main thread.
actor SessionMonitor {
    private let builder = SnapshotBuilder()

    func snapshot() -> DashboardSnapshot { builder.build() }
}

@MainActor
@Observable
final class DashboardModel {
    static let refreshInterval: Duration = .seconds(2)

    private(set) var snapshot: DashboardSnapshot = .empty
    /// Newest first; what the graph page's activity log shows.
    private(set) var activity: [ActivityEvent] = []
    static let activityLimit = 50
    var page: DashboardPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "page") }
    }
    private(set) var hasLoaded = false
    var searchText = ""
    var scope: SessionScope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: "scope") }
    }
    /// Session waiting for the user to confirm opening it (sessions not started in Claude Desktop get imported).
    var pendingImport: SessionInfo?
    var errorMessage: String?

    private let monitor = SessionMonitor()
    private var pollTask: Task<Void, Never>?

    init() {
        scope = UserDefaults.standard.string(forKey: "scope").flatMap(SessionScope.init(rawValue:)) ?? .day
        page = UserDefaults.standard.string(forKey: "page").flatMap(DashboardPage.init(rawValue:)) ?? .dashboard
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    private func refresh() async {
        let next = await monitor.snapshot()
        // Equal snapshots are not re-published, so idle refreshes do not re-render the UI.
        // The first result is always taken, even if empty: it is the baseline the activity log diffs against.
        guard !hasLoaded || next.projects != snapshot.projects || next.issues != snapshot.issues else {
            hasLoaded = true
            return
        }
        let events = ActivityFeed.events(from: snapshot, to: next, at: next.generatedAt)
        if !events.isEmpty { activity = Array((events.reversed() + activity).prefix(Self.activityLimit)) }
        snapshot = next
        hasLoaded = true
    }

    var visibleProjects: [ProjectGroup] {
        DashboardFilter.apply(to: snapshot.projects, scope: scope, query: searchText, now: Date())
    }

    // MARK: Actions

    /// Opens the session in Claude Desktop. Sessions started elsewhere are imported, which deserves a confirmation.
    func open(_ session: SessionInfo) {
        if ClaudeDeepLink.continuesInPlace(session) {
            launch(session)
        } else {
            pendingImport = session
        }
    }

    func confirmImport() {
        guard let session = pendingImport else { return }
        pendingImport = nil
        launch(session)
    }

    private func launch(_ session: SessionInfo) {
        guard let url = ClaudeDeepLink.url(for: session) else {
            errorMessage = String(localized: "This session has no identifier Claude can open.")
            return
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            errorMessage = String(localized: "Claude for Mac is not installed. Install it from claude.ai/download.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func revealInFinder(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = String(localized: "The file no longer exists.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
