import Foundation

/// One `~/.claude/sessions/<pid>.json` file: written by every running Claude Code process and kept up to date
/// with the session's status (`idle` / `busy` / `waiting`).
struct LiveSessionRecord: Decodable, Sendable, Equatable {
    let pid: Int32
    let sessionId: String?
    let cwd: String?
    let startedAt: Date?
    let kind: String?
    let entrypoint: String?
    /// Claude Desktop's `local_…` session id when the process is hosted by the desktop app.
    let hostSessionId: String?
    let name: String?
    /// Who named the session: `user`, `peer`, `derived` (from the folder), `auto`, …
    let nameSource: String?
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: Date?
    /// Set while the session is parked as a background job; Claude Code itself skips these when listing peers.
    let parkedJobId: String?
    /// Pre-warmed process that has not been claimed by a session yet.
    let spare: Bool

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, kind, entrypoint, hostSessionId, name, nameSource, status, waitingFor
        case statusUpdatedAt, updatedAt, parkedJobId, spare
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = c.lenient(String.self, .sessionId)
        cwd = c.lenient(String.self, .cwd)
        startedAt = Timestamp.fromMilliseconds(c.lenient(Double.self, .startedAt))
        kind = c.lenient(String.self, .kind)
        entrypoint = c.lenient(String.self, .entrypoint)
        hostSessionId = c.lenient(String.self, .hostSessionId)
        name = c.lenient(String.self, .name)
        nameSource = c.lenient(String.self, .nameSource)
        status = c.lenient(String.self, .status)
        waitingFor = c.lenient(String.self, .waitingFor)
        statusUpdatedAt = Timestamp.fromMilliseconds(
            c.lenient(Double.self, .statusUpdatedAt) ?? c.lenient(Double.self, .updatedAt))
        parkedJobId = c.lenient(String.self, .parkedJobId)
        spare = c.lenient(Bool.self, .spare) ?? false
    }

    /// The name Claude Code itself would display: only names given by a person (or a peer session).
    var displayName: String? {
        guard let name, !name.isEmpty, nameSource == nil || nameSource == "user" || nameSource == "peer" else { return nil }
        return name
    }

    /// Mirrors Claude Code's own mapping: anything that is not `idle`/`waiting` counts as busy.
    var sessionStatus: SessionStatus {
        switch status {
        case "waiting": .needsInput
        case "idle", nil: .idle
        default: .running
        }
    }

    var surface: SessionSurface {
        if let kind, kind != "interactive" { return .background }
        return SessionSurface(entrypoint: entrypoint)
    }
}

enum LiveSessionRegistry {
    /// Live sessions keyed by session id. Dead, parked and spare registrations are dropped.
    static func load(directory: URL, isAlive: (Int32, Date?) -> Bool) -> [String: LiveSessionRecord] {
        var result: [String: LiveSessionRecord] = [:]
        let decoder = JSONDecoder()
        for url in FileManager.default.children(of: directory) where url.pathExtension == "json" {
            // A file can be mid-rewrite; it is simply picked up on the next refresh.
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(LiveSessionRecord.self, from: data),
                  let sessionId = record.sessionId,
                  record.parkedJobId == nil, !record.spare,
                  isAlive(record.pid, record.startedAt)
            else { continue }
            // A session resumed in a second process registers twice; the most recently updated one wins.
            if let existing = result[sessionId],
               (existing.statusUpdatedAt ?? .distantPast) >= (record.statusUpdatedAt ?? .distantPast) {
                continue
            }
            result[sessionId] = record
        }
        return result
    }
}
