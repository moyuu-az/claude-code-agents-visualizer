import Foundation
@testable import AgentsVisualizerCore

/// A throwaway home directory laid out like a real one (`.claude/`, Claude Desktop's session index, repos).
final class Fixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "agents-visualizer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    var claudeDirectory: URL { home.appending(path: ".claude", directoryHint: .isDirectory) }
    var desktopDirectory: URL {
        home.appending(path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory)
    }

    func url(_ relativePath: String) -> URL { home.appending(path: relativePath) }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func writeJSON(_ relativePath: String, _ object: [String: Any]) throws -> URL {
        try write(relativePath, Self.json(object))
    }

    @discardableResult
    func writeJSONL(_ relativePath: String, _ objects: [[String: Any]]) throws -> URL {
        try write(relativePath, objects.map(Self.json).joined(separator: "\n") + "\n")
    }

    func append(_ relativePath: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url(relativePath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
    }

    func environment(alive: Set<Int32> = [], desktopRunning: Bool = true) -> ClaudeEnvironment {
        ClaudeEnvironment(
            claudeDirectory: claudeDirectory, desktopSessionsDirectory: desktopDirectory, homeDirectory: home,
            isProcessAlive: { pid, _ in alive.contains(pid) }, isDesktopAppRunning: { desktopRunning })
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builders for transcript lines in the shape Claude Code writes them.
enum Line {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func user(_ text: String, at date: Date = Date(), cwd: String? = nil, branch: String? = nil,
                     extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["type": "user", "timestamp": iso(date), "message": ["role": "user", "content": text]]
        if let cwd { object["cwd"] = cwd }
        if let branch { object["gitBranch"] = branch }
        return object.merging(extra) { $1 }
    }

    static func toolResult(at date: Date = Date()) -> [String: Any] {
        ["type": "user", "timestamp": iso(date),
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]]]
    }

    static func assistantText(_ text: String, stopReason: String? = "end_turn", at date: Date = Date(),
                              messageId: String = "msg_1") -> [String: Any] {
        ["type": "assistant", "timestamp": iso(date),
         "message": ["id": messageId, "role": "assistant", "stop_reason": stopReason.map { $0 as Any } ?? NSNull(),
                     "content": [["type": "text", "text": text]]]]
    }

    static func assistantTool(_ name: String, input: [String: Any], at date: Date = Date(),
                              messageId: String = "msg_2") -> [String: Any] {
        ["type": "assistant", "timestamp": iso(date),
         "message": ["id": messageId, "role": "assistant", "stop_reason": "tool_use",
                     "content": [["type": "tool_use", "id": "toolu_1", "name": name, "input": input]]]]
    }

    static func assistantThinking(stopReason: String?, at date: Date = Date(), messageId: String = "msg_2") -> [String: Any] {
        ["type": "assistant", "timestamp": iso(date),
         "message": ["id": messageId, "role": "assistant", "stop_reason": stopReason.map { $0 as Any } ?? NSNull(),
                     "content": [["type": "thinking", "thinking": "…"]]]]
    }

    static func customTitle(_ title: String) -> [String: Any] { ["type": "custom-title", "customTitle": title] }

    static func taskNotification(agentId: String, status: String, at date: Date = Date()) -> [String: Any] {
        ["type": "queue-operation", "operation": "enqueue", "timestamp": iso(date),
         "content": "<task-notification>\n<task-id>\(agentId)</task-id>\n<status>\(status)</status>\n<summary>done</summary>\n</task-notification>"]
    }
}
