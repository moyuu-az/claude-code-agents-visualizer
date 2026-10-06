import Foundation

/// `claude://` URLs understood by Claude Desktop.
///
/// Ids come from files on disk, so they are validated against the exact patterns Claude Desktop accepts
/// before being placed in a URL: a crafted id can never smuggle extra query parameters or path segments.
public enum ClaudeDeepLink {
    /// Same pattern Claude Desktop uses to validate `claude://code/continue?session=`.
    static var desktopIdPattern: Regex<Substring> { /^local_[A-Za-z0-9-]{1,64}$/ }
    static var uuidPattern: Regex<Substring> { /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/ }

    /// URL that opens `session` in Claude Desktop, or nil when there is no valid id to open.
    ///
    /// - Desktop sessions open in place (`claude://code/continue?session=local_…`).
    /// - Terminal/IDE sessions are imported into Claude Desktop by their CLI id (`claude://resume?session=<uuid>`).
    public static func url(for session: SessionInfo) -> URL? {
        if let desktopId = session.desktopSessionId, desktopId.wholeMatch(of: desktopIdPattern) != nil {
            return URL(string: "claude://code/continue?session=\(desktopId)")
        }
        if session.id.wholeMatch(of: uuidPattern) != nil {
            return URL(string: "claude://resume?session=\(session.id)")
        }
        return nil
    }

    /// Terminal command that resumes the session with the Claude Code CLI.
    public static func resumeCommand(for session: SessionInfo) -> String? {
        guard session.id.wholeMatch(of: uuidPattern) != nil else { return nil }
        return "cd \(shellQuoted(session.cwd)) && claude --resume \(session.id)"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
