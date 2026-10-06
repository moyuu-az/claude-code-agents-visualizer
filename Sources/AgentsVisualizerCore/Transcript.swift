import Foundation

/// Where the last turn of a transcript stands, judged from its final user/assistant entry.
enum TurnState: Equatable, Sendable {
    /// Assistant replied without requesting a tool: the turn (or a subagent's whole run) is over.
    case finished
    /// The user pressed Esc / the run was cancelled.
    case interrupted
    /// A tool call, tool result or prompt is still waiting for the next step.
    case inProgress
    case unknown
}

/// What the dashboard needs from a `.jsonl` transcript, extracted from its first and last few hundred KB.
/// Transcripts reach tens of MB, so they are never read in full.
struct TranscriptSummary: Equatable, Sendable {
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var firstPrompt: String?
    var startedAt: Date?

    var customTitle: String?
    var aiTitle: String?
    var lastPrompt: String?
    var relocatedCwd: String?
    var lastActivityAt: Date?
    var turnState: TurnState = .unknown
    /// The tool call in flight when the transcript ends with an unanswered tool_use.
    var activity: String?

    var title: String? { customTitle ?? aiTitle ?? firstPrompt ?? lastPrompt }
    /// Sessions that were opened and closed without a single prompt are noise on the dashboard.
    var hasContent: Bool { title != nil }
}

/// Parses transcripts, caching per file and re-reading only the tail when the file grows.
final class TranscriptReader {
    static let headBytes = 512 * 1024
    static let tailBytes = 512 * 1024

    private struct Entry {
        var stamp: FileStamp
        var head: TranscriptSummary
        /// The head holds everything it can ever hold (found all fields, or the file outgrew the head window).
        var headIsFinal: Bool
        var summary: TranscriptSummary
    }

    private var cache: [URL: Entry] = [:]

    func summary(of url: URL) -> TranscriptSummary? {
        guard let stamp = FileStamp.of(url) else {
            cache[url] = nil
            return nil
        }
        if let cached = cache[url], cached.stamp == stamp { return cached.summary }
        // The head of an append-only file never changes; reuse it unless the file was replaced/truncated.
        let head: TranscriptSummary
        if let cached = cache[url], cached.stamp.size <= stamp.size, cached.headIsFinal {
            head = cached.head
        } else {
            head = Self.parseHead(FileChunk.head(of: url, maxBytes: Self.headBytes) ?? Data())
        }
        let headIsFinal = (head.cwd != nil && head.firstPrompt != nil) || stamp.size >= UInt64(Self.headBytes)
        var summary = head
        if let tail = FileChunk.tail(of: url, maxBytes: Self.tailBytes) {
            Self.applyTail(tail.data, isWholeFile: tail.isWholeFile, to: &summary)
        }
        if summary.lastActivityAt == nil { summary.lastActivityAt = stamp.modified }
        cache[url] = Entry(stamp: stamp, head: head, headIsFinal: headIsFinal, summary: summary)
        return summary
    }

    /// Drops cache entries for files that are no longer referenced.
    func retain(only urls: Set<URL>) {
        cache = cache.filter { urls.contains($0.key) }
    }

    // MARK: Parsing (static for testability)

    static func parseHead(_ data: Data) -> TranscriptSummary {
        var summary = TranscriptSummary()
        // The last line of the chunk may be cut off; JSON parsing rejects it, which is what we want.
        for object in JSONLines.objects(in: data, dropFirstFragment: false) {
            let type = object["type"] as? String
            if summary.cwd == nil { summary.cwd = object["cwd"] as? String }
            if summary.gitBranch == nil { summary.gitBranch = object["gitBranch"] as? String }
            if summary.entrypoint == nil { summary.entrypoint = object["entrypoint"] as? String }
            if summary.startedAt == nil, type == "user" || type == "assistant" {
                summary.startedAt = Timestamp.parse(object["timestamp"] as? String)
            }
            if summary.firstPrompt == nil, type == "user" {
                summary.firstPrompt = promptText(of: object)
            }
            if summary.cwd != nil, summary.firstPrompt != nil { break }
        }
        return summary
    }

    static func applyTail(_ data: Data, isWholeFile: Bool, to summary: inout TranscriptSummary) {
        let objects = JSONLines.objects(in: data, dropFirstFragment: !isWholeFile)
        var sawTitle = false, sawAITitle = false, sawPrompt = false, sawRelocation = false, sawBranch = false
        var conversation: [[String: Any]] = []  // trailing user/assistant entries, newest first
        var turnClosed = false

        for object in objects.reversed() {
            switch object["type"] as? String {
            case "custom-title" where !sawTitle:
                sawTitle = true
                summary.customTitle = nonEmpty(object["customTitle"] as? String) ?? summary.customTitle
            case "ai-title" where !sawAITitle:
                sawAITitle = true
                summary.aiTitle = nonEmpty(object["aiTitle"] as? String) ?? summary.aiTitle
            case "last-prompt" where !sawPrompt:
                sawPrompt = true
                summary.lastPrompt = condense(object["lastPrompt"] as? String) ?? summary.lastPrompt
            case "relocated" where !sawRelocation:
                sawRelocation = true
                summary.relocatedCwd = object["relocatedCwd"] as? String
            case "user", "assistant":
                if !sawBranch, let branch = object["gitBranch"] as? String, branch != "HEAD" {
                    sawBranch = true
                    summary.gitBranch = branch
                }
                if summary.lastActivityAt == nil {
                    summary.lastActivityAt = Timestamp.parse(object["timestamp"] as? String)
                }
                // Collect the trailing run of entries that belong to the current step.
                if !turnClosed {
                    conversation.append(object)
                    // A user entry closes the step: everything older belongs to earlier steps.
                    if object["type"] as? String == "user" { turnClosed = true }
                }
            default:
                break
            }
        }
        (summary.turnState, summary.activity) = turnState(newestFirst: conversation)
    }

    /// Classifies the newest step. `newestFirst` holds assistant entries (each content block of a message is written
    /// as its own line, sharing the message id) followed by at most one user entry.
    static func turnState(newestFirst entries: [[String: Any]]) -> (TurnState, String?) {
        guard let newest = entries.first else { return (.unknown, nil) }
        if newest["type"] as? String == "user" {
            if let text = promptText(of: newest, keepMarkers: true), text.hasPrefix("[Request interrupted by user") {
                return (.interrupted, nil)
            }
            return (.inProgress, nil)
        }
        // Only blocks of the newest message count; an older message's tool_use was answered long ago.
        func messageId(_ entry: [String: Any]) -> String? { (entry["message"] as? [String: Any])?["id"] as? String }
        let newestId = messageId(newest)
        let assistantEntries = entries.prefix { $0["type"] as? String == "assistant" && messageId($0) == newestId }
        let messages = assistantEntries.compactMap { $0["message"] as? [String: Any] }
        let pendingTool = messages.lazy
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .first { $0["type"] as? String == "tool_use" }
        if let pendingTool {
            return (.inProgress, ToolActivity.describe(pendingTool))
        }
        let stopReason = messages.lazy.compactMap { $0["stop_reason"] as? String }.first
        switch stopReason {
        case "tool_use", nil: return (.inProgress, nil)
        default: return (.finished, nil)
        }
    }

    /// The human-typed text of a user entry, or nil for tool results, meta entries and harness-injected tags.
    static func promptText(of object: [String: Any], keepMarkers: Bool = false) -> String? {
        if object["isMeta"] as? Bool == true { return nil }
        guard let message = object["message"] as? [String: Any] else { return nil }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = nil
        }
        guard let text = condense(text) else { return nil }
        if keepMarkers { return text }
        // `<command-name>`, `<task-notification>`, `[Request interrupted…` and similar are not prompts.
        if text.hasPrefix("<") || text.hasPrefix("[") { return nil }
        return text
    }

    /// Collapses whitespace and caps length so a pasted log does not become a title.
    static func condense(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }
}

/// Human-readable one-liner for a tool_use block, e.g. "Bash · Run the test suite".
enum ToolActivity {
    static func describe(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "Tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let detail: String?
        switch name {
        case "Bash":
            detail = (input["description"] as? String) ?? (input["command"] as? String)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            detail = ((input["file_path"] as? String) ?? (input["notebook_path"] as? String))
                .map { URL(fileURLWithPath: $0).lastPathComponent }
        case "Grep", "Glob":
            detail = input["pattern"] as? String
        case "Agent", "Task":
            detail = (input["description"] as? String) ?? (input["subagent_type"] as? String)
        case "WebFetch":
            detail = (input["url"] as? String).flatMap { URL(string: $0)?.host() }
        case "WebSearch":
            detail = input["query"] as? String
        default:
            detail = nil
        }
        let shortName = name.hasPrefix("mcp__") ? (name.split(separator: "__").last.map(String.init) ?? name) : name
        guard let detail = TranscriptReader.condense(detail, limit: 80) else { return shortName }
        return "\(shortName) · \(detail)"
    }
}

enum JSONLines {
    /// Parses newline-delimited JSON objects; malformed or truncated lines are skipped.
    static func objects(in data: Data, dropFirstFragment: Bool) -> [[String: Any]] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if dropFirstFragment, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }
}

enum FileChunk {
    static func head(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    /// The last `maxBytes` of the file, and whether that is the entire file (so no partial first line).
    static func tail(of url: URL, maxBytes: Int) -> (data: Data, isWholeFile: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, start == 0)
    }

    /// Bytes from `offset` to the end of the file.
    static func read(_ url: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}
