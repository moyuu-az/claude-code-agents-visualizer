import Foundation

/// Which sessions the dashboard shows. Live sessions are always shown; the scope only limits ended ones.
public enum SessionScope: String, CaseIterable, Identifiable, Sendable {
    case live, day, week, all

    public var id: String { rawValue }

    public func includes(_ session: SessionInfo, now: Date) -> Bool {
        if session.status.isLive { return true }
        let window: TimeInterval
        switch self {
        case .live: return false
        case .all: return true
        case .day: window = 24 * 3600
        case .week: window = 7 * 24 * 3600
        }
        return session.lastActivityAt.map { now.timeIntervalSince($0) <= window } ?? false
    }
}

public enum DashboardFilter {
    /// Projects restricted to sessions in `scope` that match `query`; projects left empty are dropped.
    public static func apply(to projects: [ProjectGroup], scope: SessionScope, query: String, now: Date) -> [ProjectGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.compactMap { project in
            let sessions = project.sessions.filter { session in
                scope.includes(session, now: now) && (query.isEmpty || matches(session, in: project, query: query))
            }
            return sessions.isEmpty ? nil : ProjectGroup(id: project.id, name: project.name, sessions: sessions)
        }
    }

    /// Case- and diacritic-insensitive match on what a user would remember about a session.
    static func matches(_ session: SessionInfo, in project: ProjectGroup, query: String) -> Bool {
        let fields: [String?] = [session.title, project.name, session.cwd, session.branch, session.worktreeName]
            + session.agents.flatMap { [$0.description, $0.agentType] }
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }
}
