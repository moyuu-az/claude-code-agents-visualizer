import Foundation

/// Merges the three data sources into one dashboard snapshot:
///
/// 1. `~/.claude/sessions/*.json` - which sessions have a live process and their status (authoritative).
/// 2. Claude Desktop's session index - titles, desktop ids (for deep links), archive flags, PRs - and its unread list.
/// 3. `~/.claude/projects/**/<id>.jsonl` transcripts - everything else, plus subagents.
///
/// Not thread-safe: it owns incremental caches. Drive it from a single actor/queue.
public final class SnapshotBuilder {
    /// SSH sessions run on another machine, so there is no local registry entry to read. Without Claude for Mac's
    /// record of the remote turn, a mirrored transcript that is mid-turn and was written this recently counts as running.
    static let remoteActivityWindow: TimeInterval = 120

    private let environment: ClaudeEnvironment
    private let desktopStore: DesktopSessionStore
    private let unreadStore: DesktopUnreadStore
    private let transcripts = TranscriptReader()
    private let subagents: SubagentScanner
    private let projects: ProjectResolver

    public init(environment: ClaudeEnvironment = .current) {
        self.environment = environment
        desktopStore = DesktopSessionStore(root: environment.desktopSessionsDirectory)
        unreadStore = DesktopUnreadStore(directory: environment.desktopLocalStorageDirectory)
        subagents = SubagentScanner(transcripts: transcripts)
        projects = ProjectResolver(homeDirectory: environment.homeDirectory)
    }

    public func build(now: Date = Date()) -> DashboardSnapshot {
        var issues: [DashboardIssue] = []
        if !FileManager.default.fileExists(atPath: environment.claudeDirectory.path) {
            issues.append(.claudeDirectoryMissing(path: environment.claudeDirectory.path))
        }

        let live = LiveSessionRegistry.load(
            directory: environment.sessionRegistryDirectory, isAlive: environment.isProcessAlive)
        let desktop = desktopStore.load()
        let unread = unreadStore.load()
        let transcriptFiles = discoverTranscripts()

        var ids = Set(live.keys)
        ids.formUnion(desktop.keys)
        ids.formUnion(transcriptFiles.keys)

        subagents.beginPass()
        var grouped: [String: (location: ProjectLocation, sessions: [SessionInfo])] = [:]
        for id in ids {
            guard let (location, session) = makeSession(
                id: id, live: live[id], desktopRecords: desktop[id] ?? [], transcript: transcriptFiles[id], unread: unread, now: now)
            else { continue }
            grouped[location.root, default: (location, [])].sessions.append(session)
        }
        subagents.endPass()
        transcripts.retain(only: Set(transcriptFiles.values).union(subagents.touchedTranscripts))

        let groups = grouped.values.map { entry in
            ProjectGroup(id: entry.location.root, name: entry.location.name, sessions: entry.sessions.sorted(by: Self.sessionOrder))
        }
        return DashboardSnapshot(generatedAt: now, projects: groups.sorted(by: Self.projectOrder), issues: issues)
    }

    private func makeSession(
        id: String, live: LiveSessionRecord?, desktopRecords: [DesktopSessionRecord], transcript: URL?,
        unread: Set<String>, now: Date
    ) -> (ProjectLocation, SessionInfo)? {
        let desktop = desktopRecords.first
        // Archived in Claude Desktop = the user dismissed it; still show it while a process is working on it.
        if desktop?.isArchived == true, live == nil { return nil }
        let summary = transcript.flatMap { transcripts.summary(of: $0) }
        // Ended sessions with no prompt at all (opened and closed) are noise.
        if live == nil, desktop == nil, summary?.hasContent != true { return nil }
        guard let cwd = live?.cwd ?? summary?.relocatedCwd ?? desktop?.cwd ?? summary?.cwd else { return nil }

        let isRemote = desktop?.sshHost != nil || transcript.map(Self.isRemoteTranscript) == true
        var status = live?.sessionStatus ?? .ended
        var activity = summary?.activity
        if live == nil, isRemote {
            let mirrorMidTurn = summary.map {
                $0.turnState == .inProgress
                    && $0.lastActivityAt.map { now.timeIntervalSince($0) < Self.remoteActivityWindow } == true
            } == true
            // Claude for Mac's record of the remote turn wins: the mirror lags it by minutes. The mirror only decides
            // for sessions the app keeps no such record of.
            let midTurn = desktop?.sshMidTurn.map { $0 && environment.isDesktopAppRunning() } ?? mirrorMidTurn
            if midTurn { status = .running }
            // A stale mirror's last tool call belongs to an earlier turn.
            if !mirrorMidTurn { activity = nil }
        }

        let agents: [AgentInfo]
        if let transcript, let live {
            agents = subagents.agents(forSessionTranscript: transcript, sessionAlive: true, processStartedAt: live.startedAt)
        } else {
            agents = []
        }

        let location = projects.resolve(cwd: cwd)
        // Running or blocked sessions already demand attention; "unread" is about a reply waiting to be read.
        // Shared by the link and the dot, so a dot never links to a record that cannot clear it.
        let canBeUnread = status == .idle || status == .ended
        // Claude can put its unread dot on any of the session's records (e.g. continued twice). Link to that one, since
        // only opening it in Claude clears the dot; otherwise the most recently active record.
        let unreadRecord = canBeUnread ? desktopRecords.first { unread.contains($0.sessionId) } : nil
        let desktopSessionId = unreadRecord?.sessionId ?? desktop?.sessionId ?? live?.hostSessionId
        let session = SessionInfo(
            id: id,
            desktopSessionId: desktopSessionId,
            title: desktop?.title ?? live?.displayName ?? summary?.title ?? String(localized: "Untitled session"),
            status: status,
            waitingFor: status == .needsInput ? live?.waitingFor : nil,
            surface: isRemote ? .ssh : (live?.surface ?? (desktop != nil ? .desktop : SessionSurface(entrypoint: summary?.entrypoint))),
            sshHost: desktop?.sshHost,
            cwd: cwd,
            worktreeName: location.worktreeName,
            branch: desktop?.branch ?? summary?.gitBranch.flatMap { $0 == "HEAD" ? nil : $0 },
            pid: live?.pid,
            startedAt: summary?.startedAt ?? desktop?.createdAt ?? live?.startedAt,
            // Claude for Mac also bumps its timestamp on merely reopening a session, so it only counts where the
            // transcript is a lagging mirror.
            lastActivityAt: [summary?.lastActivityAt, live?.statusUpdatedAt, isRemote ? desktop?.lastActivityAt : nil]
                .compactMap { $0 }.max() ?? desktop?.lastActivityAt,
            activity: status == .running ? activity : nil,
            agents: agents,
            pullRequests: desktop?.pullRequests ?? [],
            transcriptPath: transcript?.path,
            model: summary?.model ?? desktop?.model,
            effort: desktop?.effort,
            isUnread: canBeUnread && desktopSessionId.map(unread.contains) == true
        )
        return (location, session)
    }

    /// `projects/<dir>/<session-id>.jsonl`, keyed by session id. Subagent transcripts live one level deeper.
    private func discoverTranscripts() -> [String: URL] {
        let fm = FileManager.default
        var result: [String: (url: URL, modified: Date)] = [:]
        for directory in fm.children(of: environment.projectsDirectory) {
            for url in fm.children(of: directory) where url.pathExtension == "jsonl" {
                let id = url.deletingPathExtension().lastPathComponent
                guard !id.hasPrefix("agent-") else { continue }  // SSH mirrors keep agent transcripts flat
                let modified = FileStamp.of(url)?.modified ?? .distantPast
                // The same session can be mirrored in two folders (e.g. an SSH mirror); keep the freshest.
                if let existing = result[id], existing.modified >= modified { continue }
                result[id] = (url, modified)
            }
        }
        return result.mapValues(\.url)
    }

    static func isRemoteTranscript(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent.hasPrefix("ssh-")
    }

    static func sessionOrder(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.status.urgency != rhs.status.urgency { return lhs.status.urgency < rhs.status.urgency }
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
        return lhs.id < rhs.id
    }

    static func projectOrder(_ lhs: ProjectGroup, _ rhs: ProjectGroup) -> Bool {
        if lhs.topStatus.urgency != rhs.topStatus.urgency { return lhs.topStatus.urgency < rhs.topStatus.urgency }
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
        return lhs.id < rhs.id
    }
}
