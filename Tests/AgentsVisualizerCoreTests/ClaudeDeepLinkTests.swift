import Foundation
import Testing
@testable import AgentsVisualizerCore

func makeSession(
    id: String = "4b8a9872-18af-4471-b2cf-eb5301cdaff3", desktopId: String? = nil, title: String = "Session",
    status: SessionStatus = .idle, cwd: String = "/repo", branch: String? = nil, worktree: String? = nil,
    lastActivityAt: Date? = nil, agents: [AgentInfo] = []
) -> SessionInfo {
    SessionInfo(
        id: id, desktopSessionId: desktopId, title: title, status: status, waitingFor: nil, surface: .desktop,
        sshHost: nil, cwd: cwd, worktreeName: worktree, branch: branch, pid: nil, startedAt: nil,
        lastActivityAt: lastActivityAt, activity: nil, agents: agents, pullRequests: [], transcriptPath: nil)
}

@Suite struct ClaudeDeepLinkTests {
    @Test func desktopSessionsContinueInPlace() {
        let session = makeSession(desktopId: "local_93b490c6-f31a-422a-9c53-b9879fcb4918")
        #expect(ClaudeDeepLink.url(for: session)?.absoluteString
                == "claude://code/continue?session=local_93b490c6-f31a-422a-9c53-b9879fcb4918")
    }

    @Test func otherSessionsAreResumedByCliId() {
        #expect(ClaudeDeepLink.url(for: makeSession())?.absoluteString
                == "claude://resume?session=4b8a9872-18af-4471-b2cf-eb5301cdaff3")
    }

    @Test(arguments: [
        "local_x&source=evil", "local_../../etc", "local_", "remote_abc", "local_" + String(repeating: "a", count: 65),
        "local_abc\n", "local_abc%26x=1", "local_a\u{301}", "local_ab\u{FF21}", " local_abc",
    ])
    func malformedDesktopIdsAreNeverPutInAUrl(desktopId: String) {
        let url = ClaudeDeepLink.url(for: makeSession(desktopId: desktopId))
        #expect(url?.absoluteString == "claude://resume?session=4b8a9872-18af-4471-b2cf-eb5301cdaff3")
    }

    @Test func longestValidDesktopIdIsAccepted() {
        let desktopId = "local_" + String(repeating: "a", count: 64)
        #expect(ClaudeDeepLink.url(for: makeSession(desktopId: desktopId))?.absoluteString
                == "claude://code/continue?session=\(desktopId)")
    }

    @Test(arguments: ["not-a-uuid", "4b8a9872-18af-4471-b2cf-eb5301cdaff3&x=1", "", "4b8a9872-18af-4471-b2cf-eb5301cdaff3\n",
                      "4b8a9872-18af-4471-b2cf-eb5301cdaff3; rm -rf ~"])
    func noValidIdMeansNoUrl(id: String) {
        #expect(ClaudeDeepLink.url(for: makeSession(id: id)) == nil)
        #expect(ClaudeDeepLink.resumeCommand(for: makeSession(id: id)) == nil)
    }

    @Test func resumeCommandQuotesThePath() {
        let session = makeSession(cwd: "/Users/me/it's here")
        #expect(ClaudeDeepLink.resumeCommand(for: session)
                == #"cd '/Users/me/it'\''s here' && claude --resume 4b8a9872-18af-4471-b2cf-eb5301cdaff3"#)
    }

    @Test func resumeCommandNeutralisesShellSyntaxInThePath() {
        let session = makeSession(cwd: "/tmp/$(touch pwned)`id`;echo")
        #expect(ClaudeDeepLink.resumeCommand(for: session)
                == "cd '/tmp/$(touch pwned)`id`;echo' && claude --resume 4b8a9872-18af-4471-b2cf-eb5301cdaff3")
    }
}

@Suite struct DashboardFilterTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func project(_ sessions: [SessionInfo], name: String = "app") -> ProjectGroup {
        ProjectGroup(id: "/code/\(name)", name: name, sessions: sessions)
    }

    @Test(arguments: [
        (SessionScope.live, [true, false, false, false]),
        (.day, [true, true, false, false]),
        (.week, [true, true, true, false]),
        (.all, [true, true, true, true]),
    ])
    func scopeLimitsOnlyEndedSessions(scope: SessionScope, expected: [Bool]) {
        let sessions = [
            makeSession(status: .running, lastActivityAt: now.addingTimeInterval(-90 * 86400)),
            makeSession(status: .ended, lastActivityAt: now.addingTimeInterval(-3600)),
            makeSession(status: .ended, lastActivityAt: now.addingTimeInterval(-3 * 86400)),
            makeSession(status: .ended, lastActivityAt: nil),
        ]
        #expect(sessions.map { scope.includes($0, now: now) } == expected)
    }

    @Test func dropsProjectsLeftEmpty() {
        let projects = [
            project([makeSession(status: .ended, lastActivityAt: now.addingTimeInterval(-30 * 86400))], name: "old"),
            project([makeSession(status: .idle)], name: "active"),
        ]
        #expect(DashboardFilter.apply(to: projects, scope: .live, query: "", now: now).map(\.name) == ["active"])
    }

    @Test(arguments: ["login", "LOGIN", "feature/auth", "brave", "app", "code-reviewer", "Find callers", "/code"])
    func searchMatchesWhatUsersRemember(query: String) {
        let agent = AgentInfo(id: "a", agentType: "code-reviewer", description: "Find callers", status: .running,
                              isBackground: false, startedAt: nil, lastActivityAt: nil, activity: nil)
        let session = makeSession(title: "Fix login", cwd: "/code/app/.claude/worktrees/brave", branch: "feature/auth",
                                  worktree: "brave", agents: [agent])
        #expect(DashboardFilter.apply(to: [project([session])], scope: .all, query: "  \(query) ", now: now).count == 1)
    }

    @Test func searchWithoutMatchesIsEmpty() {
        let projects = [project([makeSession(title: "Fix login")])]
        #expect(DashboardFilter.apply(to: projects, scope: .all, query: "payments", now: now).isEmpty)
    }
}
