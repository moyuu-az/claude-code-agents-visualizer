import Foundation

struct ProjectLocation: Equatable, Sendable {
    /// Grouping key: the main repository root (worktrees fold into it) or the session directory.
    let root: String
    let name: String
    /// Set when the session runs inside a linked git worktree.
    let worktreeName: String?
}

/// Maps a session's working directory to the project it belongs to.
final class ProjectResolver {
    private let home: String
    private var cache: [String: ProjectLocation] = [:]

    init(homeDirectory: URL) {
        home = homeDirectory.standardizedFileURL.path
    }

    func resolve(cwd rawCwd: String) -> ProjectLocation {
        let cwd = URL(fileURLWithPath: rawCwd).standardizedFileURL.path
        if let cached = cache[cwd] { return cached }
        if let scratch = scratchLocation(for: cwd) { return scratch }

        var location: ProjectLocation?
        var directory = cwd
        while true {
            location = gitLocation(at: directory)
            let parent = (directory as NSString).deletingLastPathComponent
            // Never climb into $HOME: a dotfiles repo at ~ must not swallow every unversioned folder.
            if location != nil || parent == directory || parent == home || parent == "/" { break }
            directory = parent
        }
        let resolved = location ?? fallbackLocation(for: cwd)
        // Directories that do not exist (yet) may become repositories later; only cache what was verified.
        if FileManager.default.fileExists(atPath: cwd) { cache[cwd] = resolved }
        return resolved
    }

    private func gitLocation(at directory: String) -> ProjectLocation? {
        let dotGit = (directory as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return location(root: directory, worktreeName: nil) }
        // Linked worktree: `.git` is a file containing `gitdir: <main>/.git/worktrees/<name>`.
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return location(root: directory, worktreeName: nil) }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") { gitDir = (directory as NSString).appendingPathComponent(gitDir) }
        gitDir = URL(fileURLWithPath: gitDir).standardizedFileURL.path
        if let range = gitDir.range(of: "/.git/worktrees/") {
            return location(root: String(gitDir[..<range.lowerBound]), worktreeName: (directory as NSString).lastPathComponent)
        }
        return location(root: directory, worktreeName: nil)  // submodule or custom layout
    }

    /// Without a readable `.git` (deleted worktree, remote SSH path), fall back to Claude's worktree convention.
    private func fallbackLocation(for cwd: String) -> ProjectLocation {
        for marker in ["/.claude/worktrees/", "/.worktrees/"] {
            if let range = cwd.range(of: marker) {
                let name = cwd[range.upperBound...].split(separator: "/").first.map(String.init)
                return location(root: String(cwd[..<range.lowerBound]), worktreeName: name)
            }
        }
        return location(root: cwd, worktreeName: nil)
    }

    /// Claude Desktop's throwaway scratch folders are grouped into a single "Scratch" project.
    private func scratchLocation(for cwd: String) -> ProjectLocation? {
        let marker = "/Library/Application Support/Claude/scratch-workspaces"
        guard let range = cwd.range(of: marker) else { return nil }
        return ProjectLocation(root: String(cwd[..<range.upperBound]), name: "Scratch", worktreeName: nil)
    }

    private func location(root: String, worktreeName: String?) -> ProjectLocation {
        let name = root == home ? "~" : (root as NSString).lastPathComponent
        return ProjectLocation(root: root, name: name, worktreeName: worktreeName)
    }
}
