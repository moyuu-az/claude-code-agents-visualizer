import Foundation
import Testing
@testable import AgentsVisualizerCore

private func data(_ objects: [[String: Any]]) -> Data {
    Data((objects.map(Fixture.json).joined(separator: "\n") + "\n").utf8)
}

@Suite struct TranscriptHeadTests {
    @Test func extractsCwdBranchEntrypointStartAndFirstPrompt() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let summary = TranscriptReader.parseHead(data([
            ["type": "permission-mode", "permissionMode": "auto"],
            Line.user("<command-name>/init</command-name>", at: start, cwd: "/repo", branch: "main",
                      extra: ["entrypoint": "cli"]),
            Line.user("Caveat", at: start, extra: ["isMeta": true]),
            Line.toolResult(at: start),
            Line.user("  Fix   the\nlogin bug  ", at: start.addingTimeInterval(5)),
        ]))
        #expect(summary.cwd == "/repo")
        #expect(summary.gitBranch == "main")
        #expect(summary.entrypoint == "cli")
        #expect(summary.startedAt == start)
        #expect(summary.firstPrompt == "Fix the login bug")
    }

    @Test func promptFromTextBlocks() {
        let line: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": "Hello there"]]]]
        #expect(TranscriptReader.parseHead(data([line])).firstPrompt == "Hello there")
    }

    @Test func truncatedLastLineIsIgnored() {
        var bytes = data([Line.user("first", cwd: "/repo")])
        bytes.append(Data(#"{"type":"user","cwd":"/other","mess"#.utf8))
        let summary = TranscriptReader.parseHead(bytes)
        #expect(summary.cwd == "/repo")
        #expect(summary.firstPrompt == "first")
    }

    @Test func emptyInput() {
        #expect(TranscriptReader.parseHead(Data()) == TranscriptSummary())
    }
}

@Suite struct TranscriptTailTests {
    private func tail(_ objects: [[String: Any]], isWholeFile: Bool = true) -> TranscriptSummary {
        var summary = TranscriptSummary()
        TranscriptReader.applyTail(data(objects), isWholeFile: isWholeFile, to: &summary)
        return summary
    }

    @Test func newestTitlesPromptRelocationAndBranchWin() {
        let summary = tail([
            Line.customTitle("Old title"),
            ["type": "ai-title", "aiTitle": "AI title"],
            ["type": "last-prompt", "lastPrompt": "first ask"],
            Line.user("x", branch: "feature/a"),
            ["type": "relocated", "relocatedCwd": "/repo/.claude/worktrees/wt"],
            Line.customTitle("New title"),
            ["type": "last-prompt", "lastPrompt": "second   ask"],
            Line.assistantText("done", at: Date(timeIntervalSince1970: 1_790_000_100)),
        ])
        #expect(summary.customTitle == "New title")
        #expect(summary.aiTitle == "AI title")
        #expect(summary.title == "New title")
        #expect(summary.lastPrompt == "second ask")
        #expect(summary.relocatedCwd == "/repo/.claude/worktrees/wt")
        #expect(summary.gitBranch == "feature/a")
        #expect(summary.lastActivityAt == Date(timeIntervalSince1970: 1_790_000_100))
    }

    @Test func newestRealModelIsReported() {
        var older = Line.assistantText("a", messageId: "m1")
        var newer = Line.assistantText("b", messageId: "m2")
        var synthetic = Line.assistantText("API error", messageId: "m3")
        older["message"] = (older["message"] as! [String: Any]).merging(["model": "claude-sonnet-5-5"]) { $1 }
        newer["message"] = (newer["message"] as! [String: Any]).merging(["model": "claude-opus-5-5"]) { $1 }
        synthetic["message"] = (synthetic["message"] as! [String: Any]).merging(["model": "<synthetic>"]) { $1 }
        #expect(tail([older, newer, synthetic]).model == "claude-opus-5-5")
        #expect(tail([Line.user("x")]).model == nil)
    }

    @Test func implausibleTimestampsAreIgnored() {
        #expect(Timestamp.parse("5000-01-01T00:00:00.000Z") == nil)
        #expect(Timestamp.parse("1999-12-31T23:59:59Z") == nil)
        #expect(Timestamp.parse("2026-10-06T10:00:00.123Z") != nil)
        #expect(Timestamp.parse("not a date") == nil)
        // A far-future first line must not become the session's start or last activity.
        let summary = TranscriptReader.parseHead(data([Line.user("x", extra: ["timestamp": "5000-01-01T00:00:00.000Z"])]))
        #expect(summary.startedAt == nil)
    }

    @Test(arguments: [
        ("2020-01-01T00:00:00Z", true), ("2019-12-31T23:59:59.999Z", false),
        ("2100-01-01T00:00:00.000Z", true), ("2100-01-01T00:00:00.001Z", false),
    ])
    func plausibleTimestampBounds(string: String, accepted: Bool) {
        #expect((Timestamp.parse(string) != nil) == accepted)
    }

    @Test func detachedHeadIsNotABranch() {
        #expect(tail([Line.user("x", branch: "HEAD")]).gitBranch == nil)
    }

    @Test func blankTitleDoesNotOverrideFallbacks() {
        var summary = TranscriptSummary()
        summary.firstPrompt = "First prompt"
        TranscriptReader.applyTail(data([Line.customTitle("   ")]), isWholeFile: true, to: &summary)
        #expect(summary.title == "First prompt")
    }

    @Test func partialFirstLineOfAWindowIsDropped() {
        var bytes = Data(#"ype":"custom-title","customTitle":"Garbage"}"#.utf8)
        bytes.append(Data("\n".utf8))
        bytes.append(data([Line.assistantText("ok")]))
        var summary = TranscriptSummary()
        TranscriptReader.applyTail(bytes, isWholeFile: false, to: &summary)
        #expect(summary.customTitle == nil)
        #expect(summary.turnState == .finished)
    }

    @Test func endTurnIsFinished() {
        let summary = tail([Line.user("go"), Line.assistantThinking(stopReason: "end_turn", messageId: "m"),
                            Line.assistantText("done", messageId: "m")])
        #expect(summary.turnState == .finished)
        #expect(summary.activity == nil)
    }

    @Test func pendingToolUseIsInProgressWithActivity() {
        let summary = tail([
            Line.user("go"),
            Line.assistantThinking(stopReason: "tool_use"),
            Line.assistantTool("Bash", input: ["command": "swift test", "description": "Run the tests"]),
        ])
        #expect(summary.turnState == .inProgress)
        #expect(summary.activity == "Bash · Run the tests")
    }

    @Test func thinkingAfterToolUseStillReportsTheTool() {
        // Blocks of one assistant message are separate lines; the tool_use may precede a trailing block.
        let summary = tail([Line.user("go"), Line.assistantTool("Read", input: ["file_path": "/a/b/Main.swift"]),
                            Line.assistantThinking(stopReason: "tool_use")])
        #expect(summary.turnState == .inProgress)
        #expect(summary.activity == "Read · Main.swift")
    }

    @Test func toolResultAndPromptAreInProgress() {
        #expect(tail([Line.assistantTool("Bash", input: [:]), Line.toolResult()]).turnState == .inProgress)
        #expect(tail([Line.assistantText("hi"), Line.user("next task")]).turnState == .inProgress)
    }

    @Test func olderMessagesToolUseDoesNotLeakIntoTheNewestMessage() {
        // Defensive: even without the tool_result line in between, a finished newer message is finished.
        let summary = tail([Line.assistantTool("Bash", input: [:], messageId: "old"),
                            Line.assistantText("All done", messageId: "new")])
        #expect(summary.turnState == .finished)
        #expect(summary.activity == nil)
    }

    @Test func missingStopReasonMeansStillStreaming() {
        #expect(tail([Line.user("go"), Line.assistantThinking(stopReason: nil)]).turnState == .inProgress)
    }

    @Test func userInterruptIsInterrupted() {
        let interrupt: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": "[Request interrupted by user]"]]]]
        #expect(tail([Line.assistantTool("Bash", input: [:]), interrupt]).turnState == .interrupted)
    }

    @Test func noConversationIsUnknown() {
        #expect(tail([Line.customTitle("t")]).turnState == .unknown)
    }
}

@Suite struct ToolActivityTests {
    @Test(arguments: [
        ("Bash", ["command": "ls -la"] as [String: String], "Bash · ls -la"),
        ("Edit", ["file_path": "/x/y/Model.swift"], "Edit · Model.swift"),
        ("Grep", ["pattern": "TODO"], "Grep · TODO"),
        ("Agent", ["description": "Review diff", "subagent_type": "code-reviewer"], "Agent · Review diff"),
        ("WebFetch", ["url": "https://example.com/a?b"], "WebFetch · example.com"),
        ("WebSearch", ["query": "swift testing"], "WebSearch · swift testing"),
        ("mcp__github__create_issue", ["title": "x"], "create_issue"),
        ("TodoWrite", [:], "TodoWrite"),
    ])
    func describes(name: String, input: [String: String], expected: String) {
        #expect(ToolActivity.describe(["name": name, "input": input]) == expected)
    }

    @Test func longDetailsAreCondensed() {
        let command = String(repeating: "a", count: 300)
        let text = ToolActivity.describe(["name": "Bash", "input": ["command": "  \(command)\n  "]])
        #expect(text.count == "Bash · ".count + 80)
        #expect(text.hasSuffix("…"))
    }

    @Test func missingNameAndInput() {
        #expect(ToolActivity.describe([:]) == "Tool")
    }
}

@Suite struct TranscriptReaderTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    @Test func missingFile() {
        #expect(TranscriptReader().summary(of: fixture.url("none.jsonl")) == nil)
    }

    @Test func refreshesWhenTheTranscriptGrows() throws {
        let reader = TranscriptReader()
        let url = try fixture.writeJSONL("t.jsonl", [Line.user("Build it", cwd: "/repo"), Line.assistantTool("Bash", input: ["command": "make"])])
        let first = try #require(reader.summary(of: url))
        #expect(first.turnState == .inProgress)
        #expect(first.firstPrompt == "Build it")

        try fixture.append("t.jsonl", [Line.toolResult(), Line.assistantText("Built.", messageId: "msg_3")]
            .map(Fixture.json).joined(separator: "\n") + "\n")
        let second = try #require(reader.summary(of: url))
        #expect(second.turnState == .finished)
        #expect(second.firstPrompt == "Build it")
    }

    @Test func headIsReparsedUntilThePromptArrives() throws {
        let reader = TranscriptReader()
        let url = try fixture.writeJSONL("t.jsonl", [["type": "mode", "cwd": "/repo"]])
        #expect(reader.summary(of: url)?.firstPrompt == nil)
        try fixture.append("t.jsonl", Fixture.json(Line.user("Now the prompt")) + "\n")
        #expect(reader.summary(of: url)?.firstPrompt == "Now the prompt")
    }

    @Test func largeFilesAreReadThroughHeadAndTailWindows() throws {
        let filler = String(repeating: "x", count: 4096)
        var lines: [[String: Any]] = [Line.user("Opening prompt", cwd: "/repo")]
        // ~2 MB of tool output between the head and tail windows.
        lines += Array(repeating: ["type": "attachment", "content": filler], count: 500)
        lines += [Line.customTitle("Final title"), Line.assistantText("bye")]
        let url = try fixture.writeJSONL("big.jsonl", lines)
        let summary = try #require(TranscriptReader().summary(of: url))
        #expect(summary.cwd == "/repo")
        #expect(summary.firstPrompt == "Opening prompt")
        #expect(summary.customTitle == "Final title")
        #expect(summary.turnState == .finished)
    }

    @Test func linesLargerThanBothWindowsDoNotBreakTheSummary() throws {
        // A pasted log as the first prompt and a huge tool output as the last entry: neither window holds a whole line.
        let huge = String(repeating: "y", count: TranscriptReader.headBytes + 1024)
        let url = try fixture.writeJSONL("t.jsonl", [
            Line.user(huge, cwd: "/repo"), Line.assistantText("ok"), ["type": "attachment", "content": huge],
        ])
        let summary = try #require(TranscriptReader().summary(of: url))
        #expect(summary.firstPrompt == nil)
        #expect(summary.turnState == .unknown)
        #expect(summary.lastActivityAt != nil)  // falls back to the file's mtime
    }

    @Test func fallsBackToModificationTimeForActivity() throws {
        let url = try fixture.writeJSONL("t.jsonl", [["type": "mode", "mode": "normal"]])
        let summary = try #require(TranscriptReader().summary(of: url))
        #expect(summary.lastActivityAt != nil)
    }

    @Test func truncatedFileIsReparsedFromScratch() throws {
        let reader = TranscriptReader()
        let url = try fixture.writeJSONL("t.jsonl", [Line.user("Original prompt", cwd: "/a"), Line.assistantText("long answer " + String(repeating: "z", count: 200))])
        #expect(reader.summary(of: url)?.firstPrompt == "Original prompt")
        try fixture.writeJSONL("t.jsonl", [Line.user("Replaced", cwd: "/b")])
        let summary = try #require(reader.summary(of: url))
        #expect(summary.firstPrompt == "Replaced")
        #expect(summary.cwd == "/b")
    }
}
