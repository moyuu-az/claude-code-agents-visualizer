import CoreGraphics
import Foundation
import Testing
@testable import AgentsVisualizerCore

@Suite struct GraphStableOrderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ id: String, _ status: SessionStatus, startedMinutesAgo: Double?, activeMinutesAgo: Double = 0) -> SessionInfo {
        SessionInfo(
            id: id, desktopSessionId: nil, title: id, status: status, waitingFor: nil, surface: .desktop, sshHost: nil,
            cwd: "/repo", worktreeName: nil, branch: nil, pid: nil,
            startedAt: startedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            lastActivityAt: now.addingTimeInterval(-activeMinutesAgo * 60), activity: nil, agents: [], pullRequests: [],
            transcriptPath: nil)
    }

    func ids(_ projects: [ProjectGroup]) -> [[String]] { projects.map { $0.sessions.map(\.id) } }

    @Test func sessionsAreLiveFirstThenNewestStartedFirst() {
        let project = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("old-live", .idle, startedMinutesAgo: 300),
            session("new-ended", .ended, startedMinutesAgo: 1),
            session("new-live", .running, startedMinutesAgo: 10),
            session("old-ended", .ended, startedMinutesAgo: 600),
        ])
        #expect(ids(DashboardFilter.stableOrder([project])) == [["new-live", "old-live", "new-ended", "old-ended"]])
    }

    /// The bug this order exists for: status flips and new activity used to reshuffle the graph every refresh.
    @Test func statusAndActivityChangesDoNotMoveAnything() {
        let before = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("a", .idle, startedMinutesAgo: 30, activeMinutesAgo: 20),
            session("b", .running, startedMinutesAgo: 20, activeMinutesAgo: 0),
            session("c", .idle, startedMinutesAgo: 10, activeMinutesAgo: 5),
        ])
        let after = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("c", .needsInput, startedMinutesAgo: 10, activeMinutesAgo: 0),
            session("a", .running, startedMinutesAgo: 30, activeMinutesAgo: 0),
            session("b", .idle, startedMinutesAgo: 20, activeMinutesAgo: 9),
        ])
        #expect(ids(DashboardFilter.stableOrder([before])) == [["c", "b", "a"]])
        #expect(ids(DashboardFilter.stableOrder([after])) == ids(DashboardFilter.stableOrder([before])))
    }

    @Test func unknownStartGoesLastAndTiesBreakById() {
        let project = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("z", .idle, startedMinutesAgo: nil),
            session("b", .idle, startedMinutesAgo: 5),
            session("a", .idle, startedMinutesAgo: 5),
        ])
        #expect(ids(DashboardFilter.stableOrder([project])) == [["a", "b", "z"]])
    }

    @Test func projectsAreLiveFirstThenByNewestSessionStart() {
        let projects = [
            ProjectGroup(id: "/ended", name: "ended", sessions: [session("e", .ended, startedMinutesAgo: 1)]),
            ProjectGroup(id: "/old", name: "old", sessions: [session("o", .needsInput, startedMinutesAgo: 600)]),
            ProjectGroup(id: "/new", name: "new", sessions: [
                session("n1", .idle, startedMinutesAgo: 900), session("n2", .ended, startedMinutesAgo: 5),
            ]),
            ProjectGroup(id: "/tie", name: "tie", sessions: [session("t", .idle, startedMinutesAgo: 600)]),
        ]
        #expect(DashboardFilter.stableOrder(projects).map(\.id) == ["/new", "/old", "/tie", "/ended"])
    }

    /// One level up: `/a` becoming the most urgent and most recently active project must not lift it above `/b`.
    @Test func statusAndActivityChangesDoNotMoveProjects() {
        let before = [
            ProjectGroup(id: "/a", name: "a", sessions: [session("a1", .idle, startedMinutesAgo: 30, activeMinutesAgo: 25)]),
            ProjectGroup(id: "/b", name: "b", sessions: [session("b1", .running, startedMinutesAgo: 20, activeMinutesAgo: 0)]),
        ]
        let after = [
            ProjectGroup(id: "/a", name: "a", sessions: [session("a1", .needsInput, startedMinutesAgo: 30, activeMinutesAgo: 0)]),
            ProjectGroup(id: "/b", name: "b", sessions: [session("b1", .idle, startedMinutesAgo: 20, activeMinutesAgo: 9)]),
        ]
        #expect(DashboardFilter.stableOrder(before).map(\.id) == ["/b", "/a"])
        #expect(DashboardFilter.stableOrder(after).map(\.id) == ["/b", "/a"])
    }

    @Test func emptyInputStaysEmpty() {
        #expect(DashboardFilter.stableOrder([]).isEmpty)
    }
}

@Suite struct GraphRowLayoutTests {
    let layout = GraphRowLayout(projectWidth: 200, session: CGSize(width: 260, height: 100), columnGap: 50,
                                zigzagGap: 20, rowGap: 12, agentGap: 10)

    @Test func sessionsAlternateColumnsWithTheSecondHalfARowLower() {
        let frames = layout.frames(projectHeight: 80, agentStacks: [nil, nil, nil, nil, nil])
        #expect(frames.sessions.map(\.minX) == [250, 530, 250, 530, 250])
        #expect(frames.sessions.map(\.minY) == [0, 56, 112, 168, 224])
        #expect(frames.sessions.allSatisfy { $0.size == layout.session })
        #expect(frames.size == CGSize(width: 790, height: 324))
    }

    /// Edges are drawn straight through the other column at a session's height, so it must hit a gap, never a card.
    @Test func everySessionCentreFallsInTheMiddleOfAGapOfTheOtherColumn() {
        let sessions = layout.frames(projectHeight: 80, agentStacks: Array(repeating: nil, count: 7)).sessions
        for (index, card) in sessions.enumerated() {
            let others = sessions.enumerated().filter { $0.offset % 2 != index % 2 }.map(\.element)
            #expect(!others.contains { $0.minY <= card.midY && card.midY <= $0.maxY })
            if let above = others.last(where: { $0.maxY < card.midY }), let below = others.first(where: { $0.minY > card.midY }) {
                #expect(card.midY - above.maxY == below.minY - card.midY)
            }
        }
    }

    @Test func projectIsCentredOnItsSessions() {
        let frames = layout.frames(projectHeight: 80, agentStacks: [nil, nil, nil])
        #expect(frames.project == CGRect(x: 0, y: 66, width: 200, height: 80))
    }

    @Test func agentStackIsCentredOnItsSessionWhenThereIsRoom() throws {
        let frames = layout.frames(projectHeight: 80, agentStacks: [CGSize(width: 250, height: 60), nil, CGSize(width: 250, height: 40)])
        let first = try #require(frames.agents[0]), third = try #require(frames.agents[2])
        #expect(first.minX == 840)
        #expect(first.midY == frames.sessions[0].midY)
        #expect(third.midY == frames.sessions[2].midY)
        #expect(frames.agents[1] == nil)
        #expect(frames.size.width == 1090)
    }

    @Test func crowdedStacksArePushedDownInOrderWithoutOverlapping() {
        let stacks = Array(repeating: CGSize(width: 250, height: 150) as CGSize?, count: 4)
        let frames = layout.frames(projectHeight: 80, agentStacks: stacks)
        let agents = frames.agents.compactMap { $0 }
        #expect(agents.count == 4)
        for (upper, lower) in zip(agents, agents.dropFirst()) {
            #expect(lower.minY == upper.maxY + layout.agentGap)
        }
        #expect(frames.size.height == agents.last?.maxY)
    }

    @Test func tallFirstStackStartsAtTheTopInsteadOfAboveIt() throws {
        let frames = layout.frames(projectHeight: 80, agentStacks: [CGSize(width: 250, height: 300)])
        let agents = try #require(frames.agents[0])
        #expect(agents.minY == 0)
        #expect(frames.sessions[0].minY == 0)
        #expect(frames.project.midY == frames.sessions[0].midY)
        #expect(frames.size.height == 300)
    }

    /// Agents start and finish all the time; the sessions and the project must not move when they do. 400 is taller
    /// than the four sessions, so the sessions are offset to centre on the project and a tall stack starts above them.
    @Test(arguments: [80, 400] as [CGFloat], [
        [nil, nil, nil, nil],
        [CGSize(width: 250, height: 300), nil, CGSize(width: 250, height: 60), nil],
        [CGSize(width: 250, height: 40), CGSize(width: 250, height: 500), CGSize(width: 250, height: 40), CGSize(width: 250, height: 40)],
    ] as [[CGSize?]])
    func agentStacksNeverMoveSessionsOrTheProject(projectHeight: CGFloat, stacks: [CGSize?]) {
        let bare = layout.frames(projectHeight: projectHeight, agentStacks: [nil, nil, nil, nil])
        let busy = layout.frames(projectHeight: projectHeight, agentStacks: stacks)
        #expect(busy.sessions == bare.sessions)
        #expect(busy.project == bare.project)
    }

    @Test func projectTallerThanItsSessionsStartsAtTheTop() throws {
        let frames = layout.frames(projectHeight: 160, agentStacks: [CGSize(width: 250, height: 40)])
        #expect(frames.project.minY == 0)
        #expect(frames.sessions[0].midY == frames.project.midY)
        #expect(try #require(frames.agents[0]).midY == frames.sessions[0].midY)
        #expect(frames.size.height == 160)
    }

    @Test func noSessionsIsJustTheProject() {
        let frames = layout.frames(projectHeight: 80, agentStacks: [])
        #expect(frames.sessions.isEmpty)
        #expect(frames.size == CGSize(width: 200, height: 80))
    }
}
