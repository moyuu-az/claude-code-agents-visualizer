import Foundation

/// One Claude Desktop "Code" session (`claude-code-sessions/<account>/<org>/local_<uuid>.json`).
/// Only the fields the dashboard needs are decoded; the files also carry large MCP/tool snapshots.
struct DesktopSessionRecord: Decodable, Sendable, Equatable {
    let sessionId: String
    let cliSessionId: String?
    let cwd: String?
    let title: String?
    let isArchived: Bool
    let createdAt: Date?
    let lastActivityAt: Date?
    let branch: String?
    let sshHost: String?
    /// Whether the app last saw the SSH session's remote turn in progress; nil when it does not record it.
    /// The file is not rewritten while the turn runs, so this and `lastActivityAt` hold from the turn's start.
    let sshMidTurn: Bool?
    let pullRequests: [PullRequestRef]
    let model: String?
    let effort: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, cliSessionId, cwd, title, isArchived, createdAt, lastActivityAt, branch, sshConfig, sshReattach, prs
        case model, effort
    }

    private struct SSHConfig: Decodable { let sshHost: String? }
    private struct SSHReattach: Decodable { let midTurn: Bool? }

    private struct PR: Decodable {
        let prNumber: Int?
        let url: String?
        let state: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cliSessionId = c.lenient(String.self, .cliSessionId)
        cwd = c.lenient(String.self, .cwd)
        title = c.lenient(String.self, .title)
        isArchived = c.lenient(Bool.self, .isArchived) ?? false
        createdAt = Timestamp.fromMilliseconds(c.lenient(Double.self, .createdAt))
        lastActivityAt = Timestamp.fromMilliseconds(c.lenient(Double.self, .lastActivityAt))
        branch = c.lenient(String.self, .branch)
        sshHost = c.lenient(SSHConfig.self, .sshConfig)?.sshHost
        sshMidTurn = c.lenient(SSHReattach.self, .sshReattach)?.midTurn
        model = c.lenient(String.self, .model)
        effort = c.lenient(String.self, .effort)
        var seen = Set<URL>()
        pullRequests = (c.lenient([PR].self, .prs) ?? []).compactMap { pr in
            // Only http(s) links are ever handed to NSWorkspace.
            guard let number = pr.prNumber, let raw = pr.url, let url = URL(string: raw),
                  url.scheme == "https" || url.scheme == "http", seen.insert(url).inserted
            else { return nil }
            return PullRequestRef(number: number, url: url, state: pr.state)
        }
    }
}

/// Reads Claude Desktop's session index, re-decoding a file only when it changes.
final class DesktopSessionStore {
    private let root: URL
    private var cache: [URL: (stamp: FileStamp, record: DesktopSessionRecord?)] = [:]

    init(root: URL) {
        self.root = root
    }

    /// Records keyed by CLI session id (the transcript id). Sessions without a CLI id are not Claude Code sessions.
    func load() -> [String: DesktopSessionRecord] {
        let fm = FileManager.default
        var seen = Set<URL>()
        var result: [String: DesktopSessionRecord] = [:]
        let files = fm.children(of: root)
            .flatMap { fm.children(of: $0) }
            .flatMap { fm.children(of: $0) }
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
        for url in files {
            seen.insert(url)
            guard let stamp = FileStamp.of(url) else { continue }
            let record: DesktopSessionRecord?
            if let cached = cache[url], cached.stamp == stamp {
                record = cached.record
            } else {
                record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DesktopSessionRecord.self, from: $0) }
                cache[url] = (stamp, record)
            }
            guard let record, let cliId = record.cliSessionId else { continue }
            if let existing = result[cliId],
               (existing.lastActivityAt ?? .distantPast) >= (record.lastActivityAt ?? .distantPast) {
                continue
            }
            result[cliId] = record
        }
        cache = cache.filter { seen.contains($0.key) }
        return result
    }
}
