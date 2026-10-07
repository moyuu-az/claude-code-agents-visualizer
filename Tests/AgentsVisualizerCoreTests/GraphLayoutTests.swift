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

    @Test func sessionsAreOldestStartedFirstWhateverTheirStatus() {
        let project = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("old-live", .idle, startedMinutesAgo: 300),
            session("new-ended", .ended, startedMinutesAgo: 1),
            session("new-live", .running, startedMinutesAgo: 10),
            session("old-ended", .ended, startedMinutesAgo: 600),
        ])
        #expect(ids(DashboardFilter.stableOrder([project])) == [["old-ended", "old-live", "new-live", "new-ended"]])
    }

    /// On the two-column graph, a session inserted above the others moves every one of them to the other column.
    @Test func aNewSessionIsAppendedWithoutMovingTheOthers() {
        let existing = [session("a", .idle, startedMinutesAgo: 30), session("b", .ended, startedMinutesAgo: 20)]
        let before = ProjectGroup(id: "/repo", name: "repo", sessions: existing)
        let after = ProjectGroup(id: "/repo", name: "repo", sessions: [session("new", .running, startedMinutesAgo: 0)] + existing)
        #expect(ids(DashboardFilter.stableOrder([before])) == [["a", "b"]])
        #expect(ids(DashboardFilter.stableOrder([after])) == [["a", "b", "new"]])
    }

    @Test func endingOrResumingASessionMovesNothing() {
        let before = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("a", .running, startedMinutesAgo: 30), session("b", .ended, startedMinutesAgo: 20),
            session("c", .idle, startedMinutesAgo: 10),
        ])
        let after = ProjectGroup(id: "/repo", name: "repo", sessions: [
            session("a", .ended, startedMinutesAgo: 30), session("b", .running, startedMinutesAgo: 20),
            session("c", .idle, startedMinutesAgo: 10),
        ])
        #expect(ids(DashboardFilter.stableOrder([after])) == ids(DashboardFilter.stableOrder([before])))
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
        #expect(ids(DashboardFilter.stableOrder([before])) == [["a", "b", "c"]])
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

    /// Projects never move for what their sessions do, including a new session starting in one of them.
    @Test func projectsAreInNameOrderWhateverTheirSessions() {
        let projects = [
            ProjectGroup(id: "/w/web", name: "web", sessions: [session("w", .running, startedMinutesAgo: 1)]),
            ProjectGroup(id: "/z/Zeta", name: "Zeta", sessions: [session("z", .needsInput, startedMinutesAgo: 5)]),
            ProjectGroup(id: "/b/app", name: "app", sessions: [session("b", .ended, startedMinutesAgo: 900)]),
            ProjectGroup(id: "/a/app", name: "app", sessions: [session("a", .idle, startedMinutesAgo: 10)]),
            ProjectGroup(id: "/m/mobile", name: "mobile", sessions: [session("m", .ended, startedMinutesAgo: 600)]),
        ]
        #expect(DashboardFilter.stableOrder(projects).map(\.id) == ["/a/app", "/b/app", "/m/mobile", "/w/web", "/z/Zeta"])
    }

    /// One level up: neither project moves when the other becomes the most urgent or most recently active.
    @Test func statusAndActivityChangesDoNotMoveProjects() {
        let before = [
            ProjectGroup(id: "/a", name: "a", sessions: [session("a1", .idle, startedMinutesAgo: 30, activeMinutesAgo: 25)]),
            ProjectGroup(id: "/b", name: "b", sessions: [session("b1", .running, startedMinutesAgo: 20, activeMinutesAgo: 0)]),
        ]
        let after = [
            ProjectGroup(id: "/a", name: "a", sessions: [session("a1", .needsInput, startedMinutesAgo: 30, activeMinutesAgo: 0)]),
            ProjectGroup(id: "/b", name: "b", sessions: [session("b1", .idle, startedMinutesAgo: 20, activeMinutesAgo: 9)]),
        ]
        #expect(DashboardFilter.stableOrder(before).map(\.id) == ["/a", "/b"])
        #expect(DashboardFilter.stableOrder(after).map(\.id) == ["/a", "/b"])
    }

    /// The snapshot hands projects over in urgency order, which changes with every status flip. `localizedStandardCompare`
    /// is not transitive for names with ignorable characters (`ａｐｐ` < `app\u{200B}` < `\u{200B}app` < `ａｐｐ`), and
    /// what a sort makes of such a cycle depends on the order it is given.
    @Test func projectOrderDoesNotDependOnTheInputOrder() {
        let projects = ["ａｐｐ", "app\u{200B}", "\u{200B}app", "web"].enumerated().map { index, name in
            ProjectGroup(id: "/\(index)", name: name, sessions: [session("s\(index)", .idle, startedMinutesAgo: 1)])
        }
        func permutations(_ items: [ProjectGroup]) -> [[ProjectGroup]] {
            items.count <= 1 ? [items] : items.indices.flatMap { index in
                var rest = items
                let first = rest.remove(at: index)
                return permutations(rest).map { [first] + $0 }
            }
        }
        #expect(Set(permutations(projects).map { DashboardFilter.stableOrder($0).map(\.id) }).count == 1)
    }

    @Test func emptyInputStaysEmpty() {
        #expect(DashboardFilter.stableOrder([]).isEmpty)
    }
}

@Suite struct GraphRowLayoutTests {
    let layout = GraphRowLayout(projectWidth: 200, session: CGSize(width: 260, height: 100),
                                agent: CGSize(width: 250, height: 40), columnGap: 50, zigzagGap: 20, rowGap: 12,
                                agentGap: 10, toggleWidth: 40)

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

@Suite struct GraphAgentLinesTests {
    let layout = GraphRowLayout.standard

    /// The point of agent lines: a project with agents on every session is no taller than without them, and every
    /// line sits level with its session so its edge runs straight.
    @Test(arguments: [1, 2, 5, 8])
    func oneLineOfAgentsPerSessionNeitherMovesNorGrowsAnything(sessions: Int) {
        let line = CGSize(width: layout.agent.width * 3 + layout.agentGap * 2, height: layout.agent.height)
        let bare = layout.frames(projectHeight: 80, agentStacks: Array(repeating: nil, count: sessions))
        let busy = layout.frames(projectHeight: 80, agentStacks: Array(repeating: line, count: sessions))
        #expect(busy.sessions == bare.sessions)
        #expect(busy.size.height == bare.size.height)
        for (session, agents) in zip(busy.sessions, busy.agents) {
            #expect(agents?.midY == session.midY)
        }
    }

    @Test(arguments: [900, 1200, 1650, 2400, 3440] as [CGFloat])
    func agentColumnsFillTheWidthRightOfTheSessionsWithRoomForTheToggle(width: CGFloat) {
        let columns = layout.agentColumns(width: width)
        func lineEnd(_ count: Int) -> CGFloat {
            layout.agentsX + CGFloat(count) * (layout.agent.width + layout.agentGap) + layout.toggleWidth
        }
        #expect(columns >= 1)
        if columns > 1 { #expect(lineEnd(columns) <= width) }
        #expect(lineEnd(columns + 1) > width)
    }

    @Test(arguments: [0, -50, 400, .nan, .infinity] as [CGFloat])
    func agentColumnsIsOneWhenNothingFits(width: CGFloat) {
        #expect(layout.agentColumns(width: width) == 1)
    }

    /// The invariant `.standard` exists for: one line of agents is no taller than a session's half row, so the lines of
    /// consecutive sessions never push each other down.
    @Test func oneAgentLineFitsInHalfASessionRow() {
        #expect(layout.agent.height + layout.agentGap <= (layout.session.height + layout.rowGap) / 2)
    }

    /// Exactly n cards and the toggle fit: n columns. Half a point less: one fewer, never a card under the scroller.
    @Test(arguments: 1...5)
    func agentColumnsAtTheExactWidthOfALine(count: Int) {
        let width = layout.agentsX + CGFloat(count) * (layout.agent.width + layout.agentGap) + layout.toggleWidth
        #expect(layout.agentColumns(width: width) == count)
        #expect(layout.agentColumns(width: width - 0.5) == max(count - 1, 1))
    }

    func agent(_ id: String, _ status: AgentStatus) -> AgentInfo {
        AgentInfo(id: id, agentType: "code-reviewer", description: id, status: status, isBackground: true,
                  startedAt: nil, lastActivityAt: nil, activity: nil)
    }

    func ids(_ agents: [AgentInfo]) -> [String] { agents.map(\.id) }

    @Test func runningAgentsComeFirstAndFinishedOnesFillTheRestOfTheLine() {
        let agents = [agent("r1", .running), agent("f1", .completed), agent("f2", .failed), agent("f3", .stopped),
                      agent("r2", .running)]
        let (shown, overflow) = GraphRowLayout.agentsToShow(agents, columns: 3, expanded: false)
        #expect(ids(shown) == ["r1", "r2", "f1"])
        #expect(overflow == 2)
    }

    @Test func expandingShowsEveryAgentAndKeepsTheOverflowForTheToggle() {
        let agents = [agent("r1", .running), agent("f1", .completed), agent("f2", .completed), agent("f3", .completed)]
        let (shown, overflow) = GraphRowLayout.agentsToShow(agents, columns: 2, expanded: true)
        #expect(ids(shown) == ["r1", "f1", "f2", "f3"])
        #expect(overflow == 2)
    }

    /// A fan-out of running agents wraps onto more lines; none of them is ever hidden behind the toggle.
    @Test func runningAgentsAreNeverHiddenEvenBeyondOneLine() {
        let agents = (1...5).map { agent("r\($0)", .running) } + [agent("f1", .completed)]
        let (shown, overflow) = GraphRowLayout.agentsToShow(agents, columns: 3, expanded: false)
        #expect(ids(shown) == ["r1", "r2", "r3", "r4", "r5"])
        #expect(overflow == 1)
    }

    @Test func noToggleWhenEverythingFits() {
        let agents = [agent("f1", .completed), agent("f2", .completed)]
        #expect(GraphRowLayout.agentsToShow(agents, columns: 2, expanded: false).overflow == 0)
        #expect(GraphRowLayout.agentsToShow(agents, columns: 2, expanded: true).overflow == 0)
        #expect(GraphRowLayout.agentsToShow([], columns: 2, expanded: false).shown.isEmpty)
    }

    /// The narrowest window still shows one agent per session, not just a toggle.
    @Test(arguments: [-2, 0, 1])
    func oneColumnStillShowsTheLatestFinishedAgent(columns: Int) {
        let agents = [agent("f1", .completed), agent("f2", .completed)]
        let (shown, overflow) = GraphRowLayout.agentsToShow(agents, columns: columns, expanded: false)
        #expect(ids(shown) == ["f1"])
        #expect(overflow == 1)
    }

    /// As many running agents as the line holds: no room is left, so every finished one goes behind the toggle.
    @Test func aLineFullOfRunningAgentsLeavesEveryFinishedOneToTheToggle() {
        let agents = [agent("f1", .completed), agent("r1", .running), agent("r2", .running), agent("f2", .failed)]
        let (shown, overflow) = GraphRowLayout.agentsToShow(agents, columns: 2, expanded: false)
        #expect(ids(shown) == ["r1", "r2"])
        #expect(overflow == 2)
        let expanded = GraphRowLayout.agentsToShow(agents, columns: 2, expanded: true)
        #expect(ids(expanded.shown) == ["r1", "r2", "f1", "f2"])
        #expect(expanded.overflow == 2)
    }

    /// Every mix of running and finished agents: no running agent is ever hidden, every finished one is either shown
    /// or counted by the toggle, a collapsed session takes one line unless more agents run than it holds, and the first
    /// card of a line (the one with the edge) is running whenever any card of its line is.
    @Test(arguments: 1...4)
    func everyMixKeepsRunningAgentsAndAccountsForFinishedOnes(columns: Int) {
        for running in 0...6 {
            for finished in 0...6 {
                let agents = (0..<finished).map { agent("f\($0)", .completed) } + (0..<running).map { agent("r\($0)", .running) }
                let collapsed = GraphRowLayout.agentsToShow(agents, columns: columns, expanded: false)
                let expanded = GraphRowLayout.agentsToShow(agents, columns: columns, expanded: true)
                let lines = GraphRowLayout.lines(collapsed.shown, columns: columns)
                #expect(Array(ids(collapsed.shown).prefix(running)) == (0..<running).map { "r\($0)" })
                #expect(collapsed.shown.count - running + collapsed.overflow == finished)
                #expect(lines.count == (agents.isEmpty ? 0 : max(1, (running + columns - 1) / columns)))
                #expect(Set(ids(expanded.shown)) == Set(ids(agents)))
                #expect(expanded.overflow == collapsed.overflow)
                for line in GraphRowLayout.lines(expanded.shown, columns: columns) {
                    #expect(line.first?.status.isActive == line.contains { $0.status.isActive })
                }
            }
        }
    }

    @Test func linesSplitInOrderWithTheLastOneShort() {
        let agents = ["a", "b", "c", "d", "e"].map { agent($0, .completed) }
        #expect(GraphRowLayout.lines(agents, columns: 2).map(ids) == [["a", "b"], ["c", "d"], ["e"]])
        #expect(GraphRowLayout.lines(agents, columns: 5).map(ids) == [["a", "b", "c", "d", "e"]])
        #expect(GraphRowLayout.lines(agents, columns: 64).map(ids) == [["a", "b", "c", "d", "e"]])
        #expect(GraphRowLayout.lines([], columns: 3).isEmpty)
    }

    /// `stride(by: 0)` traps; a zero or negative column count must not take the graph down with it.
    @Test(arguments: [0, -1, Int.min])
    func linesOfNoColumnsHoldOneCardEach(columns: Int) {
        let agents = ["a", "b"].map { agent($0, .running) }
        #expect(GraphRowLayout.lines(agents, columns: columns).map(ids) == [["a"], ["b"]])
    }
}

@Suite struct ProjectNameLineTests {
    @Test(arguments: [
        ("claude-code-agents-visualizer", "claude-code-\nagents-visualizer"),
        ("dexerials_minutes_app", "dexerials_\nminutes_app"),
        ("my project name", "my \nproject name"),
        ("api.example.com", "api.\nexample.com"),
    ])
    func breaksAfterTheSeparatorNearestTheMiddle(name: String, expected: String) {
        #expect(GraphRowLayout.twoLineName(name) == expected)
    }

    /// Nothing to break at, or only at the very start or end: the text view wraps it as best it can. A break after a
    /// leading separator would leave it alone on the first line and truncate the rest of the name on the second.
    @Test(arguments: ["Scratch", "議事録アプリ", "trailing-", "", "-", "--", "_averyveryverylongprojectname", ".dotfiles"])
    func namesWithoutAnInnerSeparatorStayAsTheyAre(name: String) {
        #expect(GraphRowLayout.twoLineName(name) == name)
    }

    @Test(arguments: [
        ("_my-project", "_my-\nproject"),
        ("議事録-アプリ-サーバー", "議事録-\nアプリ-サーバー"),
        ("a-b", "a-\nb"),
    ])
    func leadingSeparatorsAndNonLatinNamesBreakAtAnInnerSeparator(name: String, expected: String) {
        #expect(GraphRowLayout.twoLineName(name) == expected)
    }
}
