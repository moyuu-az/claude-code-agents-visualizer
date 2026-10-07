import AppKit  // NSRunningApplication only
import Darwin
import Foundation

/// Locations of the on-disk state written by Claude Code and Claude Desktop.
///
/// Everything here is an undocumented implementation detail of those apps, so every reader in this
/// module treats the data as untrusted and optional: a file that fails to parse is skipped, never fatal.
public struct ClaudeEnvironment: Sendable {
    /// `~/.claude`: `sessions/<pid>.json` (live process registry) and `projects/<dir>/<session>.jsonl` (transcripts).
    public var claudeDirectory: URL
    /// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`.
    public var desktopSessionsDirectory: URL
    public var homeDirectory: URL
    /// Injected so tests can simulate live and dead processes.
    public var isProcessAlive: @Sendable (_ pid: Int32, _ registeredAt: Date?) -> Bool
    /// Injected like `isProcessAlive`.
    public var isDesktopAppRunning: @Sendable () -> Bool

    public init(
        claudeDirectory: URL, desktopSessionsDirectory: URL, homeDirectory: URL,
        isProcessAlive: @escaping @Sendable (Int32, Date?) -> Bool = ProcessProbe.isAlive,
        isDesktopAppRunning: @escaping @Sendable () -> Bool = ProcessProbe.isClaudeDesktopRunning
    ) {
        self.claudeDirectory = claudeDirectory
        self.desktopSessionsDirectory = desktopSessionsDirectory
        self.homeDirectory = homeDirectory
        self.isProcessAlive = isProcessAlive
        self.isDesktopAppRunning = isDesktopAppRunning
    }

    public static var current: ClaudeEnvironment { from(environment: ProcessInfo.processInfo.environment) }

    /// - `CLAUDE_CONFIG_DIR`: the same override Claude Code honours for `~/.claude`.
    /// - `AGENTS_VISUALIZER_DESKTOP_SESSIONS_DIR`: points at a copy of Claude Desktop's session index
    ///   (demo data, debugging a user's report without touching the live files).
    static func from(environment: [String: String]) -> ClaudeEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func directory(_ key: String) -> URL? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return ClaudeEnvironment(
            claudeDirectory: directory("CLAUDE_CONFIG_DIR") ?? home.appending(path: ".claude", directoryHint: .isDirectory),
            desktopSessionsDirectory: directory("AGENTS_VISUALIZER_DESKTOP_SESSIONS_DIR") ?? home.appending(
                path: "Library/Application Support/Claude/claude-code-sessions", directoryHint: .isDirectory),
            homeDirectory: home
        )
    }

    var sessionRegistryDirectory: URL { claudeDirectory.appending(path: "sessions", directoryHint: .isDirectory) }
    var projectsDirectory: URL { claudeDirectory.appending(path: "projects", directoryHint: .isDirectory) }
}

public enum ProcessProbe {
    /// Whether `pid` is a running process that can be the one that registered a session at `registeredAt`.
    ///
    /// Registry files outlive crashed processes, and macOS recycles PIDs, so "a process with this PID exists"
    /// is not enough: a process that started *after* the session was registered cannot be its owner.
    public static func isAlive(pid: Int32, registeredAt: Date?) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        if info.kp_proc.p_stat == SZOMB { return false }
        guard let registeredAt else { return true }
        let started = info.kp_proc.p_un.__p_starttime
        let startDate = Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1e6)
        // Small tolerance for clock granularity between the two timestamps.
        return startDate <= registeredAt.addingTimeInterval(2)
    }

    /// Claude for Mac holds the SSH connections of its remote sessions; while it is not running, nothing on this Mac
    /// drives them and their records in its session index go stale.
    public static func isClaudeDesktopRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty
    }
}

// MARK: - Lenient decoding helpers

extension KeyedDecodingContainer {
    /// Decodes a value if present and of the expected type; schema drift yields `nil` instead of failing the record.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

enum Timestamp {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// ISO-8601 with or without fractional seconds (both appear in transcripts).
    /// ISO8601DateFormatter is documented thread-safe, hence `nonisolated(unsafe)`.
    static func parse(_ string: String?) -> Date? {
        guard let string, let date = fractional.date(from: string) ?? plain.date(from: string) else { return nil }
        // A corrupt or hand-edited line can carry any year; such dates would sort first forever and overflow
        // date ranges in the UI. Claude Code did not exist before 2020.
        return plausible.contains(date) ? date : nil
    }

    static let plausible = Date(timeIntervalSince1970: 1_577_836_800)...Date(timeIntervalSince1970: 4_102_444_800)  // 2020–2100

    /// Epoch milliseconds as used by the session registry and Claude Desktop.
    static func fromMilliseconds(_ value: Double?) -> Date? {
        guard let value, value.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: value / 1000)
        return plausible.contains(date) ? date : nil  // same reasoning as `parse`
    }
}

/// Cache key for parsed files: re-parse only when size or mtime changes.
struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date

    static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return FileStamp(size: size, modified: modified)
    }
}

extension FileManager {
    /// Directory listing that treats a missing or unreadable directory as empty.
    func children(of url: URL) -> [URL] {
        (try? contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }
}
