import Foundation

/// `<session>/subagents/agent-<id>.meta.json`, written when a session spawns a subagent.
struct SubagentMeta: Decodable, Equatable {
    let agentType: String?
    let description: String?
    /// "background" for `run_in_background` agents, whose completion is reported via `<task-notification>`.
    let requestShape: String?

    enum CodingKeys: String, CodingKey { case agentType, description, requestShape }

    init(agentType: String?, description: String?, requestShape: String?) {
        self.agentType = agentType
        self.description = description
        self.requestShape = requestShape
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentType = c.lenient(String.self, .agentType)
        description = c.lenient(String.self, .description)
        requestShape = c.lenient(String.self, .requestShape)
    }
}

/// A `<task-notification>` the parent session received about one of its background agents.
struct TaskNotice: Equatable, Sendable {
    let status: String
    let at: Date?

    var agentStatus: AgentStatus {
        switch status {
        case "completed": .completed
        case "failed", "error": .failed
        default: .stopped  // killed, stopped, cancelled…
        }
    }
}

enum SubagentStatusResolver {
    /// Combines the agent's own transcript with what its parent was told.
    ///
    /// - The agent transcript is authoritative when it shows a clean finish or a user interrupt.
    /// - A parent notice only counts if it is not older than the agent's last entry: an agent that was resumed
    ///   with SendMessage after a notice is running again.
    /// - Anything unfinished in a session whose process is gone was cut off, not running. The same holds when the
    ///   session is alive again in a newer process (resumed after a crash or an app restart): agents run inside the
    ///   process that spawned them, so one last heard from before the current process started died with the old one.
    static func resolve(
        turnState: TurnState, lastEntryAt: Date?, notice: TaskNotice?, sessionAlive: Bool, processStartedAt: Date? = nil
    ) -> AgentStatus {
        switch turnState {
        case .finished: return .completed
        case .interrupted: return .stopped
        case .inProgress, .unknown: break
        }
        if let notice {
            let noticeIsCurrent = switch (notice.at, lastEntryAt) {
            case let (noticeAt?, entryAt?): noticeAt >= entryAt.addingTimeInterval(-1)
            default: true
            }
            if noticeIsCurrent { return notice.agentStatus }
        }
        if let processStartedAt, let lastEntryAt, lastEntryAt < processStartedAt { return .interrupted }
        return sessionAlive ? .running : .interrupted
    }
}

/// Incrementally indexes `<task-notification>` entries of parent transcripts. Only the bytes appended since the
/// previous refresh are read, so multi-MB transcripts cost nothing after the first pass.
final class TaskNoticeIndex {
    private struct State {
        var offset: UInt64 = 0
        var notices: [String: TaskNotice] = [:]
    }

    private static let marker = Data("<task-notification>".utf8)
    private let chunkBytes: Int
    private var states: [URL: State] = [:]

    init(chunkBytes: Int = 8 * 1024 * 1024) {
        self.chunkBytes = chunkBytes
    }

    func notices(in url: URL) -> [String: TaskNotice] {
        guard let stamp = FileStamp.of(url) else {
            states[url] = nil
            return [:]
        }
        var state = states[url] ?? State()
        if stamp.size < state.offset { state = State() }  // truncated or replaced: start over
        // Bounded chunks: a first pass over a 100 MB transcript must not load it into memory at once.
        while stamp.size > state.offset, let data = FileChunk.read(url, from: state.offset, maxBytes: chunkBytes),
              !data.isEmpty {
            // Only consume complete lines; a half-written last line is picked up next time.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                // One line longer than a chunk (huge tool output): skip it whole unless it is the unfinished tail.
                if data.count < chunkBytes { break }
                state.offset += UInt64(data.count)
                continue
            }
            let complete = data[data.startIndex...lastNewline]
            autoreleasepool { Self.collect(from: complete, into: &state.notices) }
            state.offset += UInt64(complete.count)
        }
        states[url] = state
        return state.notices
    }

    func retain(only urls: Set<URL>) {
        states = states.filter { urls.contains($0.key) }
    }

    static func collect(from data: Data, into notices: inout [String: TaskNotice]) {
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let at = Timestamp.parse(object["timestamp"] as? String)
            for text in textBlocks(of: object) {
                for (taskId, status) in parse(text) {
                    // Notices arrive in order; the newest one per task wins.
                    notices[taskId] = TaskNotice(status: status, at: at)
                }
            }
        }
    }

    /// `queue-operation` entries carry the text in `content`; `user` entries in `message.content`.
    private static func textBlocks(of object: [String: Any]) -> [String] {
        if let content = object["content"] as? String { return [content] }
        guard let message = object["message"] as? [String: Any] else { return [] }
        if let content = message["content"] as? String { return [content] }
        return ((message["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
    }

    /// Extracts (task-id, status) pairs from one or more `<task-notification>` blocks.
    static func parse(_ text: String) -> [(String, String)] {
        // `<result>` is the agent's own final output: it can quote other notifications verbatim, which must not be
        // mistaken for real ones. Real blocks put their task-id/status before it.
        let text = text.replacing(/<result>.*?<\/result>/.dotMatchesNewlines(), with: "")
        return text.components(separatedBy: "<task-notification>").dropFirst().compactMap { block in
            guard let id = value(of: "task-id", in: block), let status = value(of: "status", in: block) else { return nil }
            return (id, status)
        }
    }

    private static func value(of tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Lists the subagents of a session with their current status.
final class SubagentScanner {
    private let transcripts: TranscriptReader
    private let notices = TaskNoticeIndex()
    private var metaCache: [URL: (stamp: FileStamp, meta: SubagentMeta?)] = [:]
    private var touched = Set<URL>()

    init(transcripts: TranscriptReader) {
        self.transcripts = transcripts
    }

    /// Call before a refresh pass; `endPass()` then evicts caches for files that were not touched.
    func beginPass() { touched.removeAll(keepingCapacity: true) }

    func endPass() {
        metaCache = metaCache.filter { touched.contains($0.key) }
        notices.retain(only: touched)
    }

    /// Transcript URLs read by this scanner during the current pass (so the shared reader keeps them cached).
    var touchedTranscripts: Set<URL> { touched }

    /// - Parameter processStartedAt: When the session's current process registered; agents last seen before that
    ///   belonged to an earlier process of the same (resumed) session.
    func agents(forSessionTranscript transcript: URL, sessionAlive: Bool, processStartedAt: Date? = nil) -> [AgentInfo] {
        let directory = transcript.deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
        let files = FileManager.default.children(of: directory)
        let agentTranscripts = files.filter { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl" }
        guard !agentTranscripts.isEmpty else { return [] }

        touched.insert(transcript)
        let parentNotices = notices.notices(in: transcript)
        var agents: [AgentInfo] = []
        for url in agentTranscripts {
            touched.insert(url)
            let id = String(url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
            let metaURL = directory.appending(path: "agent-\(id).meta.json")
            touched.insert(metaURL)
            let meta = loadMeta(metaURL)
            guard let summary = transcripts.summary(of: url) else { continue }
            let status = SubagentStatusResolver.resolve(
                turnState: summary.turnState, lastEntryAt: summary.lastActivityAt,
                notice: parentNotices[id], sessionAlive: sessionAlive, processStartedAt: processStartedAt)
            agents.append(AgentInfo(
                id: id,
                agentType: meta?.agentType ?? "agent",
                description: meta?.description ?? summary.firstPrompt ?? id,
                status: status,
                isBackground: meta?.requestShape == "background",
                startedAt: summary.startedAt,
                lastActivityAt: summary.lastActivityAt,
                activity: status == .running ? summary.activity : nil
            ))
        }
        // Running agents first (newest first), then the rest by most recent activity.
        return agents.sorted { lhs, rhs in
            if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
            let lhsDate = lhs.status.isActive ? lhs.startedAt : lhs.lastActivityAt
            let rhsDate = rhs.status.isActive ? rhs.startedAt : rhs.lastActivityAt
            return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
        }
    }

    private func loadMeta(_ url: URL) -> SubagentMeta? {
        guard let stamp = FileStamp.of(url) else { return nil }
        if let cached = metaCache[url], cached.stamp == stamp { return cached.meta }
        let meta = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SubagentMeta.self, from: $0) }
        metaCache[url] = (stamp, meta)
        return meta
    }
}
