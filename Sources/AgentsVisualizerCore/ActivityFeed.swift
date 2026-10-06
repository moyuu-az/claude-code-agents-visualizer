import Foundation

/// Something that happened between two refreshes, for the live activity log.
public struct ActivityEvent: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case sessionStarted
        case turnStarted
        case needsInput
        case turnFinished
        case sessionEnded
        case agentSpawned
        case agentFinished(AgentStatus)
    }

    public let id: UUID
    public let at: Date
    public let kind: Kind
    public let projectName: String
    public let sessionId: String
    public let sessionTitle: String
    public let agentType: String?
    public let agentDescription: String?
}

public enum ActivityFeed {
    /// Events implied by the change from `old` to `new`.
    ///
    /// The first snapshot yields nothing: everything would look "new" and flood the log. Sessions that drop out of
    /// the snapshot (archived, filtered) produce nothing either; only observed transitions count.
    public static func events(from old: DashboardSnapshot, to new: DashboardSnapshot, at now: Date) -> [ActivityEvent] {
        guard old.generatedAt != .distantPast else { return [] }
        let previous = Dictionary(old.allSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [ActivityEvent] = []

        for project in new.projects {
            for session in project.sessions {
                func event(_ kind: ActivityEvent.Kind, agent: AgentInfo? = nil) -> ActivityEvent {
                    ActivityEvent(id: UUID(), at: now, kind: kind, projectName: project.name, sessionId: session.id,
                                  sessionTitle: session.title, agentType: agent?.agentType,
                                  agentDescription: agent?.description)
                }

                guard let before = previous[session.id] else {
                    if session.status.isLive { events.append(event(.sessionStarted)) }
                    for agent in session.agents where agent.status.isActive { events.append(event(.agentSpawned, agent: agent)) }
                    continue
                }

                if before.status != session.status {
                    switch session.status {
                    case .needsInput: events.append(event(.needsInput))
                    case .running: events.append(event(before.status.isLive ? .turnStarted : .sessionStarted))
                    case .idle: if before.status == .ended { events.append(event(.sessionStarted)) } else { events.append(event(.turnFinished)) }
                    case .ended: events.append(event(.sessionEnded))
                    }
                }

                let earlier = Dictionary(before.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for agent in session.agents {
                    switch (earlier[agent.id]?.status, agent.status) {
                    case (nil, .running):
                        events.append(event(.agentSpawned, agent: agent))
                    case (nil, let status) where before.status.isLive:
                        // Started and finished between two refreshes. Only a live session's agent list is complete:
                        // ended sessions list none (SnapshotBuilder), so on resume the whole history reappears.
                        events.append(event(.agentFinished(status), agent: agent))
                    case (.running?, let status) where status != .running:
                        events.append(event(.agentFinished(status), agent: agent))
                    default:
                        break
                    }
                }
            }
        }
        return events
    }
}
