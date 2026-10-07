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
    let pullRequests: [PullRequestRef]
    let model: String?
    let effort: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, cliSessionId, cwd, title, isArchived, createdAt, lastActivityAt, branch, sshConfig, prs, model, effort
    }

    private struct SSHConfig: Decodable { let sshHost: String? }

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

/// Claude for Mac's unread sessions: the dot in its sidebar, set when a turn finishes while you look elsewhere and
/// cleared when you open the session. Claude keeps the list only in its web view's Local Storage (a Chromium LevelDB)
/// under `epitaxy-unread-v1`, as `{"state":{"unreadIds":["local_…"],"explicitUnreadIds":[…]},"version":0}`.
///
/// Reads the database files without taking LevelDB's lock and never writes them. Claude moves recent writes from the
/// `.log` into new `.ldb` tables every minute or so, so the value can sit in any file; the highest sequence wins.
final class DesktopUnreadStore {
    /// Chromium's Local Storage key: `_` + origin, a NUL, then `\u{1}` (Latin-1 string) + the page's key.
    static let key = Array("_https://claude.ai".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)

    private let directory: URL
    private var cache: [URL: (stamp: FileStamp, newest: LevelDB.Entry?)] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Desktop session ids (`local_…`); empty when Claude for Mac is not installed or the value cannot be read.
    func load() -> Set<String> {
        var seen = Set<URL>()
        var newest: LevelDB.Entry?
        for url in FileManager.default.children(of: directory) where ["log", "ldb"].contains(url.pathExtension) {
            guard let stamp = FileStamp.of(url) else { continue }
            seen.insert(url)
            let entry: LevelDB.Entry?
            if let cached = cache[url], cached.stamp == stamp {
                entry = cached.newest
            } else {
                // A file deleted by a compaction between listing and reading is simply skipped.
                entry = (try? Data(contentsOf: url)).flatMap { data in
                    url.pathExtension == "log" ? LevelDB.newest(Self.key, inLog: [UInt8](data))
                        : LevelDB.newest(Self.key, inTable: [UInt8](data))
                }
                cache[url] = (stamp, entry)
            }
            if let entry, entry.sequence >= (newest?.sequence ?? 0) { newest = entry }
        }
        cache = cache.filter { seen.contains($0.key) }
        return newest?.value.flatMap(Self.decode) ?? []
    }

    private struct Payload: Decodable {
        struct State: Decodable {
            let unreadIds: [String]
            /// Marked unread by hand; Claude keeps these even while the session is open.
            let explicitUnreadIds: [String]?
        }
        let state: State
    }

    /// Local Storage values start with an encoding byte: 0 = UTF-16LE, 1 = Latin-1.
    static func decode(_ value: [UInt8]) -> Set<String>? {
        guard let encoding = value.first else { return nil }
        let body = Data(value.dropFirst())
        guard let text = String(data: body, encoding: encoding == 0 ? .utf16LittleEndian : .isoLatin1),
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8))
        else { return nil }
        return Set(payload.state.unreadIds + (payload.state.explicitUnreadIds ?? []))
    }
}
