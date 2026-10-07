import Foundation
import Testing
@testable import AgentsVisualizerCore

/// End-to-end: a fake home with all three data sources, read the way the app reads them.
@Suite struct SnapshotBuilderTests {
    let fixture: Fixture
    let now = Date()
    init() throws { fixture = try Fixture() }

    private let desktopBase = "Library/Application Support/Claude/claude-code-sessions/acct/org"
    private let uuidA = "aaaaaaaa-0000-4000-8000-000000000001"
    private let uuidB = "bbbbbbbb-0000-4000-8000-000000000002"
    private let uuidC = "cccccccc-0000-4000-8000-000000000003"
    private let uuidD = "dddddddd-0000-4000-8000-000000000004"

    private func register(pid: Int32, session: String, cwd: String, status: String, extra: [String: Any] = [:]) throws {
        var object: [String: Any] = ["pid": pid, "sessionId": session, "cwd": cwd, "status": status,
                                     "startedAt": (now.timeIntervalSince1970 - 600) * 1000,
                                     "statusUpdatedAt": now.timeIntervalSince1970 * 1000, "kind": "interactive",
                                     "entrypoint": "claude-desktop"]
        object.merge(extra) { $1 }
        try fixture.writeJSON(".claude/sessions/\(pid).json", object)
    }

    private func transcript(_ dir: String, _ id: String, _ lines: [[String: Any]]) throws {
        try fixture.writeJSONL(".claude/projects/\(dir)/\(id).jsonl", lines)
    }

    private func desktopSession(_ id: String, cli: String, _ fields: [String: Any]) throws {
        var object: [String: Any] = ["sessionId": id, "cliSessionId": cli]
        object.merge(fields) { $1 }
        try fixture.writeJSON("\(desktopBase)/\(id).json", object)
    }

    private func build(alive: Set<Int32>) -> DashboardSnapshot {
        SnapshotBuilder(environment: fixture.environment(alive: alive)).build(now: now)
    }

    @Test func mergesSourcesIntoProjectsWithStatusesAndAgents() throws {
        let repo = fixture.url("code/app").path
        let worktree = fixture.url("code/app/.claude/worktrees/brave").path
        try fixture.makeDirectory("code/app/.git/worktrees/brave")
        try fixture.write("code/app/.claude/worktrees/brave/.git", "gitdir: \(repo)/.git/worktrees/brave")
        let other = fixture.url("code/lib").path
        try fixture.makeDirectory("code/lib/.git")

        // A: desktop session, busy, with one running and one finished agent, inside a worktree.
        try register(pid: 101, session: uuidA, cwd: worktree, status: "busy", extra: ["hostSessionId": "local_a"])
        try desktopSession("local_a", cli: uuidA, ["title": "Ship the feature", "branch": "feature/brave", "cwd": worktree])
        try transcript("-code-app--claude-worktrees-brave", uuidA, [
            Line.user("Ship it", cwd: worktree),
            Line.assistantTool("Agent", input: ["description": "Review the diff"]),
        ])
        try fixture.writeJSONL(".claude/projects/-code-app--claude-worktrees-brave/\(uuidA)/subagents/agent-r1.jsonl",
                               [Line.user("review"), Line.assistantTool("Read", input: ["file_path": "/x/Diff.swift"])])
        try fixture.writeJSON(".claude/projects/-code-app--claude-worktrees-brave/\(uuidA)/subagents/agent-r1.meta.json",
                              ["agentType": "code-reviewer", "description": "Review the diff"])
        try fixture.writeJSONL(".claude/projects/-code-app--claude-worktrees-brave/\(uuidA)/subagents/agent-d1.jsonl",
                               [Line.user("explore"), Line.assistantText("found it")])

        // B: terminal session waiting for a permission prompt in the main checkout.
        try register(pid: 102, session: uuidB, cwd: repo, status: "waiting",
                     extra: ["waitingFor": "approve Bash", "entrypoint": "cli", "name": "Refactor", "nameSource": "user"])
        try transcript("-code-app", uuidB, [Line.user("Refactor the parser", cwd: repo)])

        // C: ended terminal session in another repo, recent.
        try transcript("-code-lib", uuidC, [
            Line.user("Bump version", at: now.addingTimeInterval(-3600), cwd: other, branch: "main"),
            Line.assistantText("Done", at: now.addingTimeInterval(-3500)),
        ])

        // D: process registered but dead -> ended; its subagents are not listed.
        try register(pid: 104, session: uuidD, cwd: other, status: "busy")
        try transcript("-code-lib", uuidD, [Line.user("Long job", cwd: other)])
        try fixture.writeJSONL(".claude/projects/-code-lib/\(uuidD)/subagents/agent-x.jsonl", [Line.user("x")])

        let snapshot = build(alive: [101, 102])
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.projects.map(\.name) == ["app", "lib"])

        let app = snapshot.projects[0]
        #expect(app.id == repo)
        #expect(app.sessions.map(\.id) == [uuidB, uuidA])  // needs-input before running

        let b = app.sessions[0]
        #expect(b.status == .needsInput)
        #expect(b.waitingFor == "approve Bash")
        #expect(b.title == "Refactor")
        #expect(b.surface == .terminal)
        #expect(b.desktopSessionId == nil)
        #expect(b.pid == 102)

        let a = app.sessions[1]
        #expect(a.status == .running)
        #expect(a.title == "Ship the feature")
        #expect(a.desktopSessionId == "local_a")
        #expect(a.worktreeName == "brave")
        #expect(a.branch == "feature/brave")
        #expect(a.activity == "Agent · Review the diff")
        #expect(a.agents.map(\.id) == ["r1", "d1"])
        #expect(a.agents.map(\.status) == [.running, .completed])
        #expect(a.runningAgentCount == 1)

        let lib = snapshot.projects[1]
        #expect(Set(lib.sessions.map(\.id)) == [uuidC, uuidD])
        #expect(lib.sessions.allSatisfy { $0.status == .ended && $0.agents.isEmpty && $0.activity == nil })
        #expect(lib.sessions.first { $0.id == uuidC }?.branch == "main")
        #expect(lib.sessions.first { $0.id == uuidC }?.title == "Bump version")

        #expect(snapshot.count(.running) == 1)
        #expect(snapshot.count(.needsInput) == 1)
        #expect(snapshot.count(.ended) == 2)
    }

    @Test func hidesArchivedAndEmptySessionsUnlessLive() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        try desktopSession("local_arch", cli: uuidA, ["title": "Archived", "isArchived": true, "cwd": repo])
        try transcript("-code-app", uuidA, [Line.user("old work", cwd: repo)])
        try transcript("-code-app", uuidB, [["type": "mode", "mode": "normal", "cwd": repo]])  // opened, never used
        try desktopSession("local_live", cli: uuidC, ["title": "Archived but busy", "isArchived": true, "cwd": repo])
        try register(pid: 7, session: uuidC, cwd: repo, status: "busy")

        let snapshot = build(alive: [7])
        #expect(snapshot.allSessions.map(\.title) == ["Archived but busy"])
    }

    @Test func agentsCutOffInAnEarlierProcessAreNotRunning() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        // Resumed 10 minutes ago in a new process (`register` sets startedAt to now - 600s).
        try register(pid: 5, session: uuidA, cwd: repo, status: "idle")
        try transcript("-code-app", uuidA, [Line.user("go", at: now.addingTimeInterval(-7200), cwd: repo)])
        let subagents = ".claude/projects/-code-app/\(uuidA)/subagents"
        try fixture.writeJSONL("\(subagents)/agent-old.jsonl", [
            Line.user("x", at: now.addingTimeInterval(-3700)),
            Line.assistantTool("Bash", input: ["command": "sleep 999"], at: now.addingTimeInterval(-3600)),
        ])
        try fixture.writeJSONL("\(subagents)/agent-new.jsonl", [
            Line.user("y", at: now.addingTimeInterval(-60)),
            Line.assistantTool("Bash", input: ["command": "make"], at: now.addingTimeInterval(-30)),
        ])
        let session = try #require(build(alive: [5]).allSessions.first)
        #expect(session.agents.map(\.id) == ["new", "old"])
        #expect(session.agents.map(\.status) == [.running, .interrupted])
        #expect(session.runningAgentCount == 1)
    }

    @Test func liveSessionWithoutTranscriptYetStillShows() throws {
        try register(pid: 9, session: uuidA, cwd: fixture.url("fresh").path, status: "idle", extra: ["hostSessionId": "local_new"])
        let session = try #require(build(alive: [9]).allSessions.first)
        #expect(session.status == .idle)
        #expect(session.desktopSessionId == "local_new")
        #expect(session.title == "Untitled session")
    }

    @Test func sshMirrorIsRunningOnlyWhileFreshAndMidTurn() throws {
        let cwd = fixture.url("remote/app").path
        try desktopSession("local_ssh1", cli: uuidA, ["title": "Remote busy", "cwd": cwd, "sshConfig": ["sshHost": "box"]])
        try transcript("ssh-\(uuidA)", uuidA, [Line.user("go", cwd: cwd), Line.assistantTool("Bash", input: ["command": "make"], at: now)])
        try desktopSession("local_ssh2", cli: uuidB, ["title": "Remote stale", "cwd": cwd, "sshConfig": ["sshHost": "box"]])
        try transcript("ssh-\(uuidB)", uuidB, [Line.user("go", cwd: cwd),
                                               Line.assistantTool("Bash", input: [:], at: now.addingTimeInterval(-3600))])
        try desktopSession("local_ssh3", cli: uuidC, ["title": "Remote done", "cwd": cwd, "sshConfig": ["sshHost": "box"]])
        try transcript("ssh-\(uuidC)", uuidC, [Line.user("go", cwd: cwd), Line.assistantText("ok", at: now)])

        let byTitle = Dictionary(uniqueKeysWithValues: build(alive: []).allSessions.map { ($0.title, $0) })
        #expect(byTitle["Remote busy"]?.status == .running)
        #expect(byTitle["Remote busy"]?.activity == "Bash · make")
        #expect(byTitle["Remote stale"]?.status == .ended)
        #expect(byTitle["Remote done"]?.status == .ended)
        #expect(byTitle.values.allSatisfy { $0.surface == .ssh && $0.sshHost == "box" })
    }

    @Test func relocatedSessionGroupsUnderItsNewFolder() throws {
        let original = fixture.url("code/top").path
        let moved = fixture.url("code/top/backend").path
        try fixture.makeDirectory("code/top/backend/.git")
        try transcript("-code-top", uuidA, [
            Line.user("start", cwd: original),
            ["type": "relocated", "relocatedCwd": moved],
            Line.assistantText("ok"),
        ])
        let project = try #require(build(alive: []).projects.first)
        #expect(project.name == "backend")
        #expect(project.sessions.first?.cwd == moved)
    }

    @Test func modelComesFromTheTranscriptAndEffortFromClaudeForMac() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        try desktopSession("local_m", cli: uuidA, ["title": "Models", "cwd": repo, "model": "claude-sonnet-5-5", "effort": "xhigh"])
        var reply = Line.assistantText("ok")
        reply["message"] = (reply["message"] as! [String: Any]).merging(["model": "claude-opus-5-5"]) { $1 }
        try transcript("-code-app", uuidA, [Line.user("go", cwd: repo), reply])
        try desktopSession("local_n", cli: uuidB, ["title": "No transcript", "cwd": repo, "model": "claude-fable-5-1"])

        let byTitle = Dictionary(uniqueKeysWithValues: build(alive: []).allSessions.map { ($0.title, $0) })
        #expect(byTitle["Models"]?.model == "claude-opus-5-5")
        #expect(byTitle["Models"]?.effort == "xhigh")
        #expect(byTitle["No transcript"]?.model == "claude-fable-5-1")
    }

    /// Claude for Mac's sidebar unread list marks finished sessions; busy or blocked ones already demand attention.
    @Test func finishedSessionsInClaudesUnreadListAreUnread() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        let cases: [(id: String, desktop: String, pid: Int32?, status: String)] = [
            (uuidA, "local_idle", 1, "idle"), (uuidB, "local_busy", 2, "busy"), (uuidC, "local_wait", 3, "waiting"),
            (uuidD, "local_ended", nil, ""),
        ]
        for item in cases {
            try desktopSession(item.desktop, cli: item.id, ["title": item.desktop, "cwd": repo])
            try transcript("-code-app", item.id, [Line.user("go", cwd: repo), Line.assistantText("done")])
            if let pid = item.pid { try register(pid: pid, session: item.id, cwd: repo, status: item.status) }
        }
        let read = "eeeeeeee-0000-4000-8000-000000000005"
        try desktopSession("local_read", cli: read, ["title": "local_read", "cwd": repo])
        try register(pid: 4, session: read, cwd: repo, status: "idle")
        let cli = "ffffffff-0000-4000-8000-000000000006"  // not a Claude for Mac session: never unread
        try register(pid: 5, session: cli, cwd: repo, status: "idle", extra: ["entrypoint": "cli"])
        try transcript("-code-app", cli, [Line.user("go", cwd: repo, extra: ["customTitle": "cli"]), Line.assistantText("done")])
        let hosted = "99999999-0000-4000-8000-000000000007"  // not in the session index yet: only the registry links it
        try register(pid: 6, session: hosted, cwd: repo, status: "idle", extra: ["hostSessionId": "local_hosted"])

        try fixture.makeDirectory("Library/Application Support/Claude/Local Storage/leveldb")
        try Data(LevelDBFile.log([(1, [.put(LevelDBFile.localStorageKey("epitaxy-unread-v1"), LevelDBFile.latin1(
            LevelDBFile.unreadValue(["local_idle", "local_busy", "local_wait", "local_ended", cli, "local_hosted"])))])]))
            .write(to: fixture.url("Library/Application Support/Claude/Local Storage/leveldb/000003.log"))

        let sessions = Dictionary(uniqueKeysWithValues: build(alive: [1, 2, 3, 4, 5, 6]).allSessions.map { ($0.id, $0) })
        #expect(sessions[uuidA]?.isUnread == true)
        #expect(sessions[uuidD]?.isUnread == true)
        #expect(sessions[uuidB]?.isUnread == false)
        #expect(sessions[uuidC]?.isUnread == false)
        #expect(sessions[read]?.isUnread == false)
        #expect(sessions[cli]?.isUnread == false)
        #expect(sessions[hosted]?.isUnread == true)
    }

    /// Claude can keep two records for one CLI session (e.g. continued twice); its dot may sit on the older one.
    @Test func unreadOnAnyDesktopRecordOfTheSessionCounts() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        try desktopSession("local_old", cli: uuidA,
                           ["title": "Old", "cwd": repo, "lastActivityAt": (now.timeIntervalSince1970 - 600) * 1000])
        try desktopSession("local_new", cli: uuidA,
                           ["title": "New", "cwd": repo, "lastActivityAt": now.timeIntervalSince1970 * 1000])
        try fixture.makeDirectory("Library/Application Support/Claude/Local Storage/leveldb")
        try Data(LevelDBFile.log([(1, [.put(LevelDBFile.localStorageKey("epitaxy-unread-v1"), LevelDBFile.latin1(
            LevelDBFile.unreadValue(["local_old"])))])]))
            .write(to: fixture.url("Library/Application Support/Claude/Local Storage/leveldb/000003.log"))

        let sessions = build(alive: []).allSessions
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.isUnread)
        // The most recently active record still supplies the title; the link opens the record whose dot it clears.
        #expect(session.title == "New")
        #expect(session.desktopSessionId == "local_old")

        // While busy, or once read, the link goes back to the most recently active record.
        try register(pid: 7, session: uuidA, cwd: repo, status: "busy")
        let busy = try #require(build(alive: [7]).allSessions.first)
        #expect(!busy.isUnread)
        #expect(busy.desktopSessionId == "local_new")
        try Data(LevelDBFile.log([(2, [.put(LevelDBFile.localStorageKey("epitaxy-unread-v1"), LevelDBFile.latin1(
            LevelDBFile.unreadValue([])))])]))
            .write(to: fixture.url("Library/Application Support/Claude/Local Storage/leveldb/000004.log"))
        let read = try #require(build(alive: []).allSessions.first)
        #expect(!read.isUnread)
        #expect(read.desktopSessionId == "local_new")
    }

    /// Among several records for one CLI session, only the most recently active one says whether it was dismissed.
    @Test func mostRecentDesktopRecordDecidesWhetherArchived() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        let earlier = (now.timeIntervalSince1970 - 600) * 1000, later = now.timeIntervalSince1970 * 1000
        try desktopSession("local_a_old", cli: uuidA, ["title": "Dismissed earlier", "isArchived": true, "cwd": repo,
                                                       "lastActivityAt": earlier])
        try desktopSession("local_a_new", cli: uuidA, ["title": "Continued", "cwd": repo, "lastActivityAt": later])
        try desktopSession("local_b_old", cli: uuidB, ["title": "Older copy", "cwd": repo, "lastActivityAt": earlier])
        try desktopSession("local_b_new", cli: uuidB, ["title": "Dismissed now", "isArchived": true, "cwd": repo,
                                                       "lastActivityAt": later])
        #expect(build(alive: []).allSessions.map(\.title) == ["Continued"])
    }

    @Test func reportsMissingClaudeDirectory() {
        let snapshot = build(alive: [])
        #expect(snapshot.issues == [.claudeDirectoryMissing(path: fixture.claudeDirectory.path)])
        #expect(snapshot.projects.isEmpty)
    }

    @Test func projectsOrderedByUrgencyThenRecency() throws {
        for (name, pid, status, ago) in [("idle-old", Int32(1), "idle", 500.0), ("idle-new", 2, "idle", 10), ("busy", 3, "busy", 900)] {
            try fixture.makeDirectory("code/\(name)/.git")
            let id = UUID().uuidString.lowercased()
            try register(pid: pid, session: id, cwd: fixture.url("code/\(name)").path, status: status,
                         extra: ["statusUpdatedAt": (now.timeIntervalSince1970 - ago) * 1000])
        }
        #expect(build(alive: [1, 2, 3]).projects.map(\.name) == ["busy", "idle-new", "idle-old"])
    }

    @Test func repeatedBuildsAreStableAndPickUpChanges() throws {
        let repo = fixture.url("code/app").path
        try fixture.makeDirectory("code/app/.git")
        try register(pid: 5, session: uuidA, cwd: repo, status: "busy")
        try transcript("-code-app", uuidA, [Line.user("go", cwd: repo), Line.assistantTool("Bash", input: ["command": "make"])])
        let builder = SnapshotBuilder(environment: fixture.environment(alive: [5]))
        let first = builder.build(now: now)
        #expect(builder.build(now: now) == first)

        try register(pid: 5, session: uuidA, cwd: repo, status: "idle")
        try fixture.append(".claude/projects/-code-app/\(uuidA).jsonl", Fixture.json(Line.assistantText("Built")) + "\n")
        let second = try #require(builder.build(now: now).allSessions.first)
        #expect(second.status == .idle)
        #expect(second.activity == nil)
        #expect(!second.isUnread)

        try fixture.makeDirectory("Library/Application Support/Claude/Local Storage/leveldb")
        try Data(LevelDBFile.log([(1, [.put(LevelDBFile.localStorageKey("epitaxy-unread-v1"), LevelDBFile.latin1(
            LevelDBFile.unreadValue(["local_a"])))])]))
            .write(to: fixture.url("Library/Application Support/Claude/Local Storage/leveldb/000003.log"))
        try desktopSession("local_a", cli: uuidA, ["cwd": repo])
        #expect(builder.build(now: now).allSessions.first?.isUnread == true)
    }
}
