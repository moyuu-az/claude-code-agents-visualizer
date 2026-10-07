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

    /// Order for the graph page, where nodes have to stay put to be followed: projects by name, sessions oldest started
    /// first. Status, activity and sessions ending never move anything, and a new session goes to the end: on the
    /// two-column graph, one inserted at the top would move every other session to the other column. The snapshot's
    /// urgency order follows status and last activity, which change every few seconds.
    public static func stableOrder(_ projects: [ProjectGroup]) -> [ProjectGroup] {
        projects
            .map { ProjectGroup(id: $0.id, name: $0.name, sessions: $0.sessions.sorted(by: stableSessionOrder)) }
            .sorted { lhs, rhs in
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.id < rhs.id
                }
            }
    }

    static func stableSessionOrder(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        // An unknown start sorts last, with the sessions that have just appeared.
        let (lhsStart, rhsStart) = (lhs.startedAt ?? .distantFuture, rhs.startedAt ?? .distantFuture)
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        return lhs.id < rhs.id
    }

    /// Case- and diacritic-insensitive match on what a user would remember about a session.
    static func matches(_ session: SessionInfo, in project: ProjectGroup, query: String) -> Bool {
        let fields: [String?] = [session.title, project.name, session.cwd, session.branch, session.worktreeName]
            + session.agents.flatMap { [$0.description, $0.agentType] }
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }
}
