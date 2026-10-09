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

/// Incrementally indexes the background work of parent transcripts: `<task-notification>` entries, and the shell
/// commands (`run_in_background`) and monitors the session started. Only the bytes appended since the previous refresh
/// are read, so multi-MB transcripts cost nothing after the first pass.
final class TaskNoticeIndex {
    private struct State {
        var offset: UInt64 = 0
        var notices: [String: TaskNotice] = [:]
        /// Background shell commands and monitors by task id, with when they started and, for a monitor with a timeout,
        /// when it expires: an expiring monitor posts only an event (`[Monitor expired …]`), never a `<status>`.
        var launches: [String: (at: Date?, expiresAt: Date?)] = [:]
    }

    /// `<task-notification>`, then the `toolUseResult` keys of a background Bash command, a Monitor and a TaskStop.
    private static let markers = ["<task-notification>", #""backgroundTaskId""#, #""persistent""#, #""task_type""#]
        .map { Data($0.utf8) }
    private let chunkBytes: Int
    private var states: [URL: State] = [:]

    init(chunkBytes: Int = 8 * 1024 * 1024) {
        self.chunkBytes = chunkBytes
    }

    func notices(in url: URL) -> [String: TaskNotice] { refresh(url).notices }

    /// Background shell commands and monitors that have not ended. Ones started before `processStartedAt` ran in an
    /// earlier process of the session and died with it.
    func runningTasks(in url: URL, processStartedAt: Date?, now: Date) -> Set<String> {
        let state = refresh(url)
        return Set(state.launches.compactMap { id, launch in
            guard state.notices[id] == nil else { return nil }
            if let processStartedAt, let startedAt = launch.at, startedAt < processStartedAt { return nil }
            if let expiresAt = launch.expiresAt, expiresAt <= now { return nil }
            return id
        })
    }

    private func refresh(_ url: URL) -> State {
        guard let stamp = FileStamp.of(url) else {
            states[url] = nil
            return State()
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
            autoreleasepool { Self.collect(from: complete, into: &state) }
            state.offset += UInt64(complete.count)
        }
        states[url] = state
        return state
    }

    func retain(only urls: Set<URL>) {
        states = states.filter { urls.contains($0.key) }
    }

    private static func collect(from data: Data, into state: inout State) {
        for line in data.split(separator: UInt8(ascii: "\n")) where markers.contains(where: { contains(line, $0) }) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let at = Timestamp.parse(object["timestamp"] as? String)
            for text in textBlocks(of: object) {
                for (taskId, status) in parse(text) {
                    // Notices arrive in order; the newest one per task wins.
                    state.notices[taskId] = TaskNotice(status: status, at: at)
                }
            }
            guard let result = object["toolUseResult"] as? [String: Any] else { continue }
            // Bash with `run_in_background` (or moved there after its timeout), then Monitor. Todo tools also return a
            // `taskId`, but no `persistent`.
            if let id = result["backgroundTaskId"] as? String {
                state.launches[id] = (at, nil)
            } else if let id = result["taskId"] as? String, result["persistent"] != nil {
                // A persistent monitor watches until the session ends; any other expires `timeoutMs` after it started.
                let timeout = result["persistent"] as? Bool == true ? nil : result["timeoutMs"] as? Double
                state.launches[id] = (at, timeout.flatMap { at?.addingTimeInterval($0 / 1000) })
            } else if let id = result["task_id"] as? String, result["task_type"] != nil {
                // TaskStop. A shell command stopped this way gets no `<task-notification>`.
                state.notices[id] = TaskNotice(status: "killed", at: at)
            }
        }
    }

    /// `memmem`: `Data.range(of:)` made the first pass over live transcripts twice as slow once there were four markers.
    private static func contains(_ line: Data, _ marker: Data) -> Bool {
        line.withUnsafeBytes { haystack in
            marker.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
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

    /// Background shell commands and monitors of a live session that are still running, by task id.
    func runningTasks(forSessionTranscript transcript: URL, processStartedAt: Date?, now: Date) -> Set<String> {
        touched.insert(transcript)
        return notices.runningTasks(in: transcript, processStartedAt: processStartedAt, now: now)
    }

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
                activity: status == .running ? summary.activity : nil,
                model: summary.model
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
