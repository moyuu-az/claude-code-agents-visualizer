import Foundation

/// Which sessions the dashboard shows. Live and unread sessions are always shown; the scope only limits the rest.
public enum SessionScope: String, CaseIterable, Identifiable, Sendable {
    case live, day, week, all

    public var id: String { rawValue }

    public func includes(_ session: SessionInfo, now: Date) -> Bool {
        if session.status.isLive || session.isUnread { return true }
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
    ///
    /// The one exception is a reply waiting to be read: the session goes to the top of its project and the project to
    /// the top of the graph, where it is seen first. That moves the graph only twice per reply, when the turn finishes
    /// while you look elsewhere and when you open the session, unlike a status that flips with every permission prompt.
    public static func stableOrder(_ projects: [ProjectGroup]) -> [ProjectGroup] {
        projects
            // A fixed starting order, not the snapshot's: `localizedStandardCompare` is not transitive for names with
            // ignorable characters such as a zero-width space, and sorting such a cycle depends on the input order.
            .sorted { $0.id < $1.id }
            .map { ProjectGroup(id: $0.id, name: $0.name, sessions: $0.sessions.sorted(by: stableSessionOrder)) }
            .sorted { lhs, rhs in
                let (lhsUnread, rhsUnread) = (lhs.unreadCount > 0, rhs.unreadCount > 0)
                if lhsUnread != rhsUnread { return lhsUnread }
                return switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.id < rhs.id
                }
            }
    }

    static func stableSessionOrder(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
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
