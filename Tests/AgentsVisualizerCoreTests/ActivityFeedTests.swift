import Foundation
import Testing
@testable import AgentsVisualizerCore

@Suite struct ActivityFeedTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(_ id: String, _ status: AgentStatus) -> AgentInfo {
        AgentInfo(id: id, agentType: "Explore", description: "Find \(id)", status: status, isBackground: true,
                  startedAt: nil, lastActivityAt: nil, activity: nil)
    }

    private func snapshot(_ sessions: [SessionInfo], at date: Date? = nil) -> DashboardSnapshot {
        DashboardSnapshot(generatedAt: date ?? t0, projects: [ProjectGroup(id: "/code/app", name: "app", sessions: sessions)], issues: [])
    }

    private func kinds(_ old: DashboardSnapshot, _ new: DashboardSnapshot) -> [ActivityEvent.Kind] {
        ActivityFeed.events(from: old, to: new, at: t0).map(\.kind)
    }

    @Test func firstSnapshotProducesNothing() {
        #expect(kinds(.empty, snapshot([makeSession(status: .running, agents: [agent("a", .running)])])).isEmpty)
    }

    @Test(arguments: [
        (SessionStatus.idle, SessionStatus.running, ActivityEvent.Kind.turnStarted),
        (.running, .needsInput, .needsInput),
        (.needsInput, .running, .turnStarted),
        (.running, .idle, .turnFinished),
        (.idle, .ended, .sessionEnded),
        (.ended, .running, .sessionStarted),
        (.ended, .idle, .sessionStarted),
    ])
    func statusTransitions(from: SessionStatus, to: SessionStatus, expected: ActivityEvent.Kind) {
        #expect(kinds(snapshot([makeSession(status: from)]), snapshot([makeSession(status: to)])) == [expected])
    }

    @Test func unchangedSnapshotIsQuiet() {
        let s = snapshot([makeSession(status: .running, agents: [agent("a", .running), agent("b", .completed)])])
        #expect(kinds(s, s).isEmpty)
    }

    @Test func newLiveSessionAndItsRunningAgents() {
        let new = snapshot([makeSession(id: "new", status: .running, agents: [agent("a", .running), agent("b", .completed)])])
        #expect(kinds(snapshot([]), new) == [.sessionStarted, .agentSpawned])
    }

    @Test func newlyDiscoveredEndedSessionIsNotAnEvent() {
        #expect(kinds(snapshot([]), snapshot([makeSession(id: "old", status: .ended)])).isEmpty)
    }

    @Test func agentLifecycle() {
        let base = makeSession(status: .running)
        let s0 = snapshot([base])
        let s1 = snapshot([makeSession(status: .running, agents: [agent("a", .running)])])
        let s2 = snapshot([makeSession(status: .running, agents: [agent("a", .completed), agent("b", .failed)])])
        #expect(kinds(s0, s1) == [.agentSpawned])
        #expect(kinds(s1, s2) == [.agentFinished(.completed), .agentFinished(.failed)])
        #expect(kinds(s2, s2).isEmpty)
    }

    // Ended sessions carry no agents (SnapshotBuilder lists them only for live sessions), so a resumed session's
    // whole subagent history shows up at once. That history is not something that just happened.
    @Test func resumedSessionDoesNotReplayItsAgentHistory() {
        let ended = snapshot([makeSession(status: .ended)])
        let resumed = snapshot([makeSession(status: .idle, agents: [agent("a", .completed), agent("b", .interrupted)])])
        #expect(kinds(ended, resumed) == [.sessionStarted])
        let busy = snapshot([makeSession(status: .running, agents: [agent("c", .running), agent("a", .completed)])])
        #expect(kinds(ended, busy) == [.sessionStarted, .agentSpawned])
    }

    @Test func agentStartedAndFinishedBetweenRefreshes() {
        let s0 = snapshot([makeSession(status: .running)])
        let s1 = snapshot([makeSession(status: .running, agents: [agent("a", .completed)])])
        #expect(kinds(s0, s1) == [.agentFinished(.completed)])
    }

    @Test func eventsCarryContext() throws {
        let old = snapshot([makeSession(title: "Ship it", status: .running)])
        let new = snapshot([makeSession(title: "Ship it", status: .running, agents: [agent("x", .running)])])
        let event = try #require(ActivityFeed.events(from: old, to: new, at: t0).first)
        #expect(event.projectName == "app")
        #expect(event.sessionTitle == "Ship it")
        #expect(event.agentType == "Explore")
        #expect(event.agentDescription == "Find x")
        #expect(event.at == t0)
    }
}

@Suite struct ModelNameTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-fable-5-1", "Fable 5.1"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("claude-opus-5-5[1m]", "Opus 5.5"), ("claude-opus-5", "Opus 5"),
        ("gpt-x", "gpt-x"),
    ])
    func formats(id: String, expected: String) {
        #expect(ModelName.display(id) == expected)
    }

    @Test func emptyIsNil() {
        #expect(ModelName.display(nil) == nil)
        #expect(ModelName.display("") == nil)
    }
}
