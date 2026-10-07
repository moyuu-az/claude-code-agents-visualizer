import Foundation

/// Lifecycle state of a Claude Code session as seen from outside the process.
public enum SessionStatus: String, Sendable, Codable, CaseIterable {
    /// Blocked on the user: a permission prompt, a question, a plan approval, etc.
    case needsInput
    /// A turn is in progress (model streaming, tools or subagents running).
    case running
    /// The process is alive and the last turn has finished; waiting for the next prompt.
    case idle
    /// No live process holds the session.
    case ended

    /// Lower ranks are more urgent and sort first.
    public var urgency: Int {
        switch self {
        case .needsInput: 0
        case .running: 1
        case .idle: 2
        case .ended: 3
        }
    }

    public var isLive: Bool { self != .ended }
}

/// Where the session's process runs / which client drives it.
public enum SessionSurface: String, Sendable, Codable {
    case desktop, terminal, vscode, ssh, background

    /// From the `entrypoint` Claude Code records in its registry and transcripts.
    init(entrypoint: String?) {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p", "local-agent": self = .desktop
        case "claude-vscode": self = .vscode
        default: self = .terminal
        }
    }
}

public enum AgentStatus: String, Sendable, Codable {
    case running
    case completed
    case failed
    /// Stopped on purpose (user interrupt or a kill from the parent).
    case stopped
    /// The parent session ended while the agent had not finished.
    case interrupted

    public var isActive: Bool { self == .running }
}

public struct AgentInfo: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let agentType: String
    public let description: String
    public let status: AgentStatus
    public let isBackground: Bool
    public let startedAt: Date?
    public let lastActivityAt: Date?
    /// Short description of the tool call in flight, e.g. "Bash · swift test".
    public let activity: String?
    /// Model id, e.g. `claude-sonnet-5-5`.
    public let model: String?

    public init(
        id: String, agentType: String, description: String, status: AgentStatus, isBackground: Bool,
        startedAt: Date?, lastActivityAt: Date?, activity: String?, model: String? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.description = description
        self.status = status
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.activity = activity
        self.model = model
    }
}

public struct PullRequestRef: Sendable, Hashable, Codable {
    public let number: Int
    public let url: URL
    public let state: String?
}

public struct SessionInfo: Identifiable, Sendable, Hashable, Codable {
    /// Claude Code (CLI) session UUID; the transcript file name.
    public let id: String
    /// Claude Desktop's `local_…` id when the session is known to the desktop app.
    public let desktopSessionId: String?
    public let title: String
    public let status: SessionStatus
    /// Free-form reason reported by Claude Code while `status == .needsInput`.
    public let waitingFor: String?
    public let surface: SessionSurface
    public let sshHost: String?
    public let cwd: String
    public let worktreeName: String?
    public let branch: String?
    public let pid: Int32?
    public let startedAt: Date?
    public let lastActivityAt: Date?
    public let activity: String?
    public let agents: [AgentInfo]
    public let pullRequests: [PullRequestRef]
    public let transcriptPath: String?
    /// Model id of the latest reply, e.g. `claude-opus-5-5`.
    public let model: String?
    /// Reasoning effort chosen in Claude for Mac (`low` … `xhigh`), when known.
    public let effort: String?

    public init(
        id: String, desktopSessionId: String?, title: String, status: SessionStatus, waitingFor: String?,
        surface: SessionSurface, sshHost: String?, cwd: String, worktreeName: String?, branch: String?,
        pid: Int32?, startedAt: Date?, lastActivityAt: Date?, activity: String?, agents: [AgentInfo],
        pullRequests: [PullRequestRef], transcriptPath: String?, model: String? = nil, effort: String? = nil
    ) {
        self.id = id
        self.desktopSessionId = desktopSessionId
        self.title = title
        self.status = status
        self.waitingFor = waitingFor
        self.surface = surface
        self.sshHost = sshHost
        self.cwd = cwd
        self.worktreeName = worktreeName
        self.branch = branch
        self.pid = pid
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.activity = activity
        self.agents = agents
        self.pullRequests = pullRequests
        self.transcriptPath = transcriptPath
        self.model = model
        self.effort = effort
    }

    public var runningAgentCount: Int { agents.count { $0.status.isActive } }

    /// `cwd` as a folder on this Mac, or nil for SSH sessions: their `cwd` is a path on the remote host, and a folder
    /// at the same path on this Mac is a different checkout. They are only ever opened as a Claude for Mac session.
    public var localCwd: String? { surface == .ssh ? nil : cwd }
}

public struct ProjectGroup: Identifiable, Sendable, Hashable, Codable {
    /// Repository root (worktrees fold into their main repository) or the session directory.
    public let id: String
    public let name: String
    public let sessions: [SessionInfo]

    public init(id: String, name: String, sessions: [SessionInfo]) {
        self.id = id
        self.name = name
        self.sessions = sessions
    }

    public var path: String { id }

    /// The most urgent status among the project's sessions.
    public var topStatus: SessionStatus {
        sessions.map(\.status).min { $0.urgency < $1.urgency } ?? .ended
    }

    public var lastActivityAt: Date? { sessions.compactMap(\.lastActivityAt).max() }
}

/// Problems worth surfacing in the UI instead of silently showing an empty dashboard.
public enum DashboardIssue: Hashable, Sendable, Codable {
    case claudeDirectoryMissing(path: String)
}

public struct DashboardSnapshot: Sendable, Hashable, Codable {
    public let generatedAt: Date
    public let projects: [ProjectGroup]
    public let issues: [DashboardIssue]

    public init(generatedAt: Date, projects: [ProjectGroup], issues: [DashboardIssue]) {
        self.generatedAt = generatedAt
        self.projects = projects
        self.issues = issues
    }

    public static let empty = DashboardSnapshot(generatedAt: .distantPast, projects: [], issues: [])

    public var allSessions: [SessionInfo] { projects.flatMap(\.sessions) }

    public func count(_ status: SessionStatus) -> Int { allSessions.count { $0.status == status } }

    /// The most urgent status across all sessions; drives the window's ambient colour.
    public var mood: SessionStatus {
        allSessions.map(\.status).min { $0.urgency < $1.urgency } ?? .ended
    }
}

public enum ModelName {
    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5"; unknown ids pass through.
    public static func display(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        guard let match = id.wholeMatch(of: /claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(?:\[.*\])?/) else { return id }
        let family = match.1.prefix(1).uppercased() + match.1.dropFirst()
        let version = match.3.map { "\(match.2).\($0)" } ?? String(match.2)
        return "\(family) \(version)"
    }
}
