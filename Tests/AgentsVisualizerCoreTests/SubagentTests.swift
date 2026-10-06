import Foundation
import Testing
@testable import AgentsVisualizerCore

@Suite struct SubagentStatusResolverTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func ownTranscriptDecidesFinishedAndInterrupted() {
        let completed = TaskNotice(status: "killed", at: t0.addingTimeInterval(100))
        #expect(SubagentStatusResolver.resolve(turnState: .finished, lastEntryAt: t0, notice: completed, sessionAlive: true) == .completed)
        #expect(SubagentStatusResolver.resolve(turnState: .interrupted, lastEntryAt: t0, notice: nil, sessionAlive: true) == .stopped)
    }

    @Test func unfinishedAgentRunsWhileTheSessionLives() {
        #expect(SubagentStatusResolver.resolve(turnState: .inProgress, lastEntryAt: t0, notice: nil, sessionAlive: true) == .running)
        #expect(SubagentStatusResolver.resolve(turnState: .unknown, lastEntryAt: nil, notice: nil, sessionAlive: true) == .running)
    }

    @Test func unfinishedAgentOfADeadSessionWasInterrupted() {
        #expect(SubagentStatusResolver.resolve(turnState: .inProgress, lastEntryAt: t0, notice: nil, sessionAlive: false) == .interrupted)
    }

    @Test(arguments: [("completed", AgentStatus.completed), ("failed", .failed), ("killed", .stopped), ("stopped", .stopped)])
    func currentNoticeEndsTheAgent(status: String, expected: AgentStatus) {
        let notice = TaskNotice(status: status, at: t0.addingTimeInterval(5))
        #expect(SubagentStatusResolver.resolve(turnState: .inProgress, lastEntryAt: t0, notice: notice, sessionAlive: true) == expected)
    }

    @Test func noticeOlderThanTheLastEntryMeansTheAgentWasResumed() {
        let notice = TaskNotice(status: "completed", at: t0)
        let resumedAt = t0.addingTimeInterval(60)
        #expect(SubagentStatusResolver.resolve(turnState: .inProgress, lastEntryAt: resumedAt, notice: notice, sessionAlive: true) == .running)
    }

    @Test func noticeWithoutTimestampsIsTrusted() {
        let notice = TaskNotice(status: "killed", at: nil)
        #expect(SubagentStatusResolver.resolve(turnState: .inProgress, lastEntryAt: t0, notice: notice, sessionAlive: true) == .stopped)
    }
}

@Suite struct TaskNoticeIndexTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    @Test func parsesOneOrMoreBlocks() {
        let text = """
        <task-notification><task-id>a1</task-id><status>completed</status></task-notification>
        <task-notification>
        <task-id> b2 </task-id>
        <status>killed</status>
        </task-notification>
        <task-notification><task-id>c3</task-id></task-notification>
        """
        let pairs = TaskNoticeIndex.parse(text)
        #expect(pairs.map(\.0) == ["a1", "b2"])
        #expect(pairs.map(\.1) == ["completed", "killed"])
    }

    @Test func readsQueueOperationsAndUserEntries() throws {
        let userString: [String: Any] = ["type": "user", "timestamp": Line.iso(Date()),
                                         "message": ["content": "<task-notification><task-id>u1</task-id><status>failed</status></task-notification>"]]
        let userBlocks: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": "<task-notification><task-id>u2</task-id><status>completed</status></task-notification>"]]]]
        let url = try fixture.writeJSONL("p.jsonl", [Line.taskNotification(agentId: "q1", status: "completed"), userString, userBlocks,
                                                      Line.user("mentions <task-notification> but is not one")])
        let notices = TaskNoticeIndex().notices(in: url)
        #expect(notices["q1"]?.status == "completed")
        #expect(notices["u1"]?.status == "failed")
        #expect(notices["u2"]?.status == "completed")
        #expect(notices.count == 3)
    }

    @Test func laterNoticeForTheSameTaskWins() throws {
        let url = try fixture.writeJSONL("p.jsonl", [Line.taskNotification(agentId: "a", status: "completed"),
                                                      Line.taskNotification(agentId: "a", status: "killed")])
        #expect(TaskNoticeIndex().notices(in: url)["a"]?.status == "killed")
    }

    @Test func readsIncrementallyAndWaitsForCompleteLines() throws {
        let index = TaskNoticeIndex()
        let url = try fixture.writeJSONL("p.jsonl", [Line.taskNotification(agentId: "a", status: "completed")])
        #expect(index.notices(in: url).keys.sorted() == ["a"])

        // Half-written line: not consumed yet.
        let next = Fixture.json(Line.taskNotification(agentId: "b", status: "killed"))
        let cut = next.index(next.startIndex, offsetBy: 40)
        try fixture.append("p.jsonl", String(next[..<cut]))
        #expect(index.notices(in: url).keys.sorted() == ["a"])

        try fixture.append("p.jsonl", String(next[cut...]) + "\n")
        #expect(index.notices(in: url).keys.sorted() == ["a", "b"])
    }

    @Test func truncatedFileIsRescanned() throws {
        let index = TaskNoticeIndex()
        let url = try fixture.writeJSONL("p.jsonl", [Line.taskNotification(agentId: "a", status: "completed"),
                                                      Line.taskNotification(agentId: "b", status: "completed")])
        #expect(index.notices(in: url).count == 2)
        try fixture.writeJSONL("p.jsonl", [Line.taskNotification(agentId: "c", status: "failed")])
        #expect(index.notices(in: url).keys.sorted() == ["c"])
    }

    @Test func missingFile() {
        #expect(TaskNoticeIndex().notices(in: fixture.url("none.jsonl")).isEmpty)
    }
}

@Suite struct SubagentScannerTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    private let session = ".claude/projects/-repo/sess"

    private func agent(_ id: String, meta: [String: Any]?, _ lines: [[String: Any]]) throws {
        if let meta { try fixture.writeJSON("\(session)/subagents/agent-\(id).meta.json", meta) }
        try fixture.writeJSONL("\(session)/subagents/agent-\(id).jsonl", lines)
    }

    @Test func listsAgentsWithStatusMetadataAndOrder() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let parent = try fixture.writeJSONL("\(session).jsonl", [
            Line.user("go"), Line.taskNotification(agentId: "killed1", status: "killed", at: t0.addingTimeInterval(50)),
        ])
        try agent("done1", meta: ["agentType": "code-reviewer", "description": "Review", "requestShape": "background"],
                  [Line.user("review", at: t0), Line.assistantText("LGTM", at: t0.addingTimeInterval(30))])
        try agent("run1", meta: ["agentType": "Explore", "description": "Find usages"],
                  [Line.user("find", at: t0.addingTimeInterval(10)),
                   Line.assistantTool("Grep", input: ["pattern": "foo"], at: t0.addingTimeInterval(11))])
        try agent("run2", meta: ["agentType": "general-purpose", "description": "Newer"],
                  [Line.user("x", at: t0.addingTimeInterval(20)), Line.toolResult(at: t0.addingTimeInterval(21))])
        try agent("killed1", meta: ["agentType": "general-purpose", "description": "Killed"],
                  [Line.user("x", at: t0), Line.assistantTool("Bash", input: ["command": "sleep 999"], at: t0.addingTimeInterval(40))])
        try agent("nometa", meta: nil, [Line.user("Untyped agent task", at: t0), Line.assistantText("ok", at: t0.addingTimeInterval(1))])
        try fixture.write("\(session)/subagents/notes.txt", "ignored")

        let scanner = SubagentScanner(transcripts: TranscriptReader())
        scanner.beginPass()
        let agents = scanner.agents(forSessionTranscript: parent, sessionAlive: true)
        scanner.endPass()

        #expect(agents.map(\.id) == ["run2", "run1", "killed1", "done1", "nometa"])
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        #expect(byId["run1"]?.status == .running)
        #expect(byId["run1"]?.activity == "Grep · foo")
        #expect(byId["run1"]?.agentType == "Explore")
        #expect(byId["done1"]?.status == .completed)
        #expect(byId["done1"]?.isBackground == true)
        #expect(byId["done1"]?.activity == nil)
        #expect(byId["killed1"]?.status == .stopped)
        #expect(byId["nometa"]?.agentType == "agent")
        #expect(byId["nometa"]?.description == "Untyped agent task")
    }

    @Test func agentsOfAnEndedSessionAreInterrupted() throws {
        let parent = try fixture.writeJSONL("\(session).jsonl", [Line.user("go")])
        try agent("a", meta: ["agentType": "Explore"], [Line.user("x"), Line.assistantTool("Bash", input: [:])])
        let agents = SubagentScanner(transcripts: TranscriptReader()).agents(forSessionTranscript: parent, sessionAlive: false)
        #expect(agents.map(\.status) == [.interrupted])
    }

    @Test func sessionWithoutSubagents() throws {
        let parent = try fixture.writeJSONL("\(session).jsonl", [Line.user("go")])
        #expect(SubagentScanner(transcripts: TranscriptReader()).agents(forSessionTranscript: parent, sessionAlive: true).isEmpty)
    }
}
