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
        if next.projects != snapshot.projects || next.issues != snapshot.issues { snapshot = next }
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
