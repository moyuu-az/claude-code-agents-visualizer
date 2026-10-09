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

    @Test func unfinishedAgentOfAnEarlierProcessWasInterrupted() {
        // The session was resumed in a new process (crash, app restart); agents die with the process that ran them.
        let restartedAt = t0.addingTimeInterval(60)
        func resolve(lastEntryAt: Date?, notice: TaskNotice? = nil, processStartedAt: Date?) -> AgentStatus {
            SubagentStatusResolver.resolve(turnState: .inProgress, lastEntryAt: lastEntryAt, notice: notice,
                                           sessionAlive: true, processStartedAt: processStartedAt)
        }
        #expect(resolve(lastEntryAt: t0, processStartedAt: restartedAt) == .interrupted)
        #expect(resolve(lastEntryAt: restartedAt, processStartedAt: restartedAt) == .running)
        #expect(resolve(lastEntryAt: restartedAt.addingTimeInterval(1), processStartedAt: restartedAt) == .running)
        // Without both timestamps there is nothing to compare: keep trusting the live session.
        #expect(resolve(lastEntryAt: t0, processStartedAt: nil) == .running)
        #expect(resolve(lastEntryAt: nil, processStartedAt: restartedAt) == .running)
        // A current notice is still more specific than "cut off".
        #expect(resolve(lastEntryAt: t0, notice: TaskNotice(status: "completed", at: t0.addingTimeInterval(5)),
                        processStartedAt: restartedAt) == .completed)
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

    @Test func notificationsQuotedInAnAgentResultAreIgnored() {
        // `<result>` is the agent's own final output and may quote other notifications verbatim.
        let text = """
        <task-notification>
        <task-id>outer</task-id>
        <status>completed</status>
        <summary>Agent "Orchestrate" finished</summary>
        <result>Child said <task-notification><task-id>sibling</task-id><status>killed</status></task-notification>
        so all good.</result>
        </task-notification>
        <task-notification><task-id>next</task-id><status>failed</status><result>boom</result></task-notification>
        """
        let pairs = TaskNoticeIndex.parse(text)
        #expect(pairs.map(\.0) == ["outer", "next"])
        #expect(pairs.map(\.1) == ["completed", "failed"])
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

    @Test func readsAcrossChunkBoundariesAndSkipsOversizedLines() throws {
        // A tiny chunk forces many partial reads; one line is longer than a whole chunk.
        let index = TaskNoticeIndex(chunkBytes: 256)
        let huge: [String: Any] = ["type": "attachment", "content": String(repeating: "x", count: 2000)]
        let url = try fixture.writeJSONL("p.jsonl", [
            Line.taskNotification(agentId: "a", status: "completed"), huge,
            Line.taskNotification(agentId: "b", status: "killed"), huge, huge,
            Line.taskNotification(agentId: "c", status: "failed"),
        ])
        let notices = index.notices(in: url)
        #expect(notices.mapValues(\.status) == ["a": "completed", "b": "killed", "c": "failed"])

        try fixture.append("p.jsonl", Fixture.json(Line.taskNotification(agentId: "d", status: "completed")) + "\n")
        #expect(index.notices(in: url).count == 4)
    }

    @Test func unfinishedOversizedTailIsRetriedLater() throws {
        let index = TaskNoticeIndex(chunkBytes: 256)
        let url = try fixture.writeJSONL("p.jsonl", [Line.taskNotification(agentId: "a", status: "completed")])
        #expect(index.notices(in: url).count == 1)
        // A notification still being written, shorter than a chunk: not consumed until its newline lands.
        let next = Fixture.json(Line.taskNotification(agentId: "b", status: "killed"))
        try fixture.append("p.jsonl", String(next.prefix(100)))
        #expect(index.notices(in: url).count == 1)
        try fixture.append("p.jsonl", String(next.dropFirst(100)) + "\n")
        #expect(index.notices(in: url)["b"]?.status == "killed")
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
        #expect(TaskNoticeIndex().runningTasks(in: fixture.url("none.jsonl"), processStartedAt: nil, now: Date()).isEmpty)
    }

    /// Shapes copied from real transcripts: `run_in_background` Bash, Monitor, and TaskStop results.
    @Test func backgroundCommandsAndMonitorsRunUntilNotifiedOrStopped() throws {
        let monitorEvent: [String: Any] = [
            "type": "queue-operation", "operation": "enqueue", "timestamp": Line.iso(Date()),
            "content": "<task-notification>\n<task-id>mon1</task-id>\n<summary>Monitor event: \"CI\"</summary>\n<event>build 3/9</event>\n</task-notification>",
        ]
        let url = try fixture.writeJSONL("p.jsonl", [
            Line.toolResult(result: ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "run1"]),
            Line.toolResult(result: ["stdout": "", "backgroundTaskId": "done1", "timedOutAfterMs": 120000]),
            Line.toolResult(result: ["stdout": "", "backgroundTaskId": "stop1"]),
            Line.toolResult(result: ["taskId": "mon1", "timeoutMs": 300000, "persistent": false]),
            Line.toolResult(result: ["taskId": "1", "updatedFields": ["status"]]),  // a todo item, not a process
            Line.taskNotification(agentId: "done1", status: "completed"),
            monitorEvent,  // an event from a monitor that keeps watching
            // TaskStop ends a shell command without a notification.
            Line.toolResult(result: ["message": "Successfully stopped task: stop1", "task_id": "stop1", "task_type": "local_bash"]),
        ])
        #expect(TaskNoticeIndex().runningTasks(in: url, processStartedAt: nil, now: Date()) == ["run1", "mon1"])
    }

    @Test func backgroundTasksOfAnEarlierProcessDiedWithIt() throws {
        let restartedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let url = try fixture.writeJSONL("p.jsonl", [
            Line.toolResult(at: restartedAt.addingTimeInterval(-60), result: ["backgroundTaskId": "old"]),
            Line.toolResult(at: restartedAt.addingTimeInterval(1), result: ["backgroundTaskId": "new"]),
        ])
        let index = TaskNoticeIndex()
        #expect(index.runningTasks(in: url, processStartedAt: restartedAt, now: Date()) == ["new"])
        #expect(index.runningTasks(in: url, processStartedAt: nil, now: Date()) == ["old", "new"])
    }

    @Test func undatedLaunchCannotBeAgedOut() throws {
        var undated = Line.toolResult(result: ["backgroundTaskId": "b1"])
        undated["timestamp"] = nil
        let url = try fixture.writeJSONL("p.jsonl", [undated])
        #expect(TaskNoticeIndex().runningTasks(in: url, processStartedAt: Date(), now: Date()) == ["b1"])
    }

    /// An expiring monitor only posts an event without `<status>`; its timeout is the only end marker.
    @Test func monitorsEndWhenTheyExpireUnlessPersistent() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let url = try fixture.writeJSONL("p.jsonl", [
            Line.toolResult(at: start, result: ["taskId": "timed", "timeoutMs": 1_800_000, "persistent": false]),
            Line.toolResult(at: start, result: ["taskId": "forever", "timeoutMs": 1_800_000, "persistent": true]),
            Line.toolResult(at: start, result: ["taskId": "noTimeout", "persistent": false]),
        ])
        let index = TaskNoticeIndex()
        #expect(index.runningTasks(in: url, processStartedAt: nil, now: start.addingTimeInterval(1799))
            == ["timed", "forever", "noTimeout"])
        #expect(index.runningTasks(in: url, processStartedAt: nil, now: start.addingTimeInterval(1800)) == ["forever", "noTimeout"])
    }

    @Test func backgroundTaskEndingInALaterRefreshIsPickedUp() throws {
        let index = TaskNoticeIndex()
        let url = try fixture.writeJSONL("p.jsonl", [Line.toolResult(result: ["backgroundTaskId": "b1"])])
        #expect(index.runningTasks(in: url, processStartedAt: nil, now: Date()) == ["b1"])
        try fixture.append("p.jsonl", Fixture.json(Line.taskNotification(agentId: "b1", status: "failed")) + "\n")
        #expect(index.runningTasks(in: url, processStartedAt: nil, now: Date()).isEmpty)
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

    @Test func brokenMetaFallsBackToDefaults() throws {
        let parent = try fixture.writeJSONL("\(session).jsonl", [Line.user("go")])
        try fixture.write("\(session)/subagents/agent-b.meta.json", #"{"agentType": 42, "description": "#)
        try fixture.writeJSONL("\(session)/subagents/agent-b.jsonl", [Line.user("Do the thing"), Line.assistantText("done")])
        let agents = SubagentScanner(transcripts: TranscriptReader()).agents(forSessionTranscript: parent, sessionAlive: true)
        #expect(agents.map(\.agentType) == ["agent"])
        #expect(agents.map(\.description) == ["Do the thing"])
        #expect(agents.map(\.status) == [.completed])
    }

    @Test func sessionWithoutSubagents() throws {
        let parent = try fixture.writeJSONL("\(session).jsonl", [Line.user("go")])
        #expect(SubagentScanner(transcripts: TranscriptReader()).agents(forSessionTranscript: parent, sessionAlive: true).isEmpty)
    }
}
