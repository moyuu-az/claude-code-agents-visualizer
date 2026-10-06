import Foundation
import Testing
@testable import AgentsVisualizerCore

@Suite struct ProjectResolverTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    private func path(_ relative: String) -> String { fixture.url(relative).path }

    @Test func repositoryRootAndSubdirectories() throws {
        try fixture.makeDirectory("code/app/.git")
        try fixture.makeDirectory("code/app/Sources/Feature")
        let resolver = ProjectResolver(homeDirectory: fixture.home)
        #expect(resolver.resolve(cwd: path("code/app")) == ProjectLocation(root: path("code/app"), name: "app", worktreeName: nil))
        #expect(resolver.resolve(cwd: path("code/app/Sources/Feature")).root == path("code/app"))
    }

    @Test func linkedWorktreeFoldsIntoItsMainRepository() throws {
        try fixture.makeDirectory("code/app/.git/worktrees/brave-otter")
        try fixture.write("code/app/.claude/worktrees/brave-otter/.git", "gitdir: \(path("code/app/.git/worktrees/brave-otter"))\n")
        let location = ProjectResolver(homeDirectory: fixture.home).resolve(cwd: path("code/app/.claude/worktrees/brave-otter"))
        #expect(location == ProjectLocation(root: path("code/app"), name: "app", worktreeName: "brave-otter"))
    }

    @Test func relativeGitdirIsResolved() throws {
        try fixture.makeDirectory("code/app/.git/worktrees/wt")
        try fixture.write("code/wt/.git", "gitdir: ../app/.git/worktrees/wt")
        let location = ProjectResolver(homeDirectory: fixture.home).resolve(cwd: path("code/wt"))
        #expect(location.root == path("code/app"))
        #expect(location.worktreeName == "wt")
    }

    @Test func submoduleStaysItsOwnProject() throws {
        try fixture.makeDirectory("code/app/.git/modules/lib")
        try fixture.write("code/app/lib/.git", "gitdir: ../.git/modules/lib")
        let location = ProjectResolver(homeDirectory: fixture.home).resolve(cwd: path("code/app/lib"))
        #expect(location == ProjectLocation(root: path("code/app/lib"), name: "lib", worktreeName: nil))
    }

    @Test func deletedWorktreeFallsBackToNamingConvention() {
        let location = ProjectResolver(homeDirectory: fixture.home).resolve(cwd: path("gone/app/.claude/worktrees/old-wt/sub"))
        #expect(location == ProjectLocation(root: path("gone/app"), name: "app", worktreeName: "old-wt"))
    }

    @Test func unversionedFolderIsItsOwnProject() throws {
        try fixture.makeDirectory("notes/2026")
        let location = ProjectResolver(homeDirectory: fixture.home).resolve(cwd: path("notes/2026"))
        #expect(location == ProjectLocation(root: path("notes/2026"), name: "2026", worktreeName: nil))
    }

    @Test func dotfilesRepoAtHomeDoesNotSwallowSubfolders() throws {
        try fixture.makeDirectory(".git")
        try fixture.makeDirectory("scratchpad")
        let resolver = ProjectResolver(homeDirectory: fixture.home)
        #expect(resolver.resolve(cwd: path("scratchpad")).root == path("scratchpad"))
        #expect(resolver.resolve(cwd: fixture.home.path) == ProjectLocation(root: fixture.home.path, name: "~", worktreeName: nil))
    }

    @Test func desktopScratchFoldersShareOneProject() {
        let resolver = ProjectResolver(homeDirectory: fixture.home)
        let a = resolver.resolve(cwd: path("Library/Application Support/Claude/scratch-workspaces/acct/org/scratch-1"))
        let b = resolver.resolve(cwd: path("Library/Application Support/Claude/scratch-workspaces/acct/org/scratch-2"))
        #expect(a == b)
        #expect(a.name == "Scratch")
    }

    @Test func folderThatBecomesARepositoryLaterIsReResolved() throws {
        let resolver = ProjectResolver(homeDirectory: fixture.home)
        let missing = path("later/app/.claude/worktrees/wt")
        #expect(resolver.resolve(cwd: missing).root == path("later/app"))
        try fixture.makeDirectory("later/app/.git/worktrees/wt")
        try fixture.write("later/app/.claude/worktrees/wt/.git", "gitdir: \(path("later/app/.git/worktrees/wt"))")
        #expect(resolver.resolve(cwd: missing) == ProjectLocation(root: path("later/app"), name: "app", worktreeName: "wt"))
    }

    @Test func trailingSlashAndDotSegmentsAreNormalised() throws {
        try fixture.makeDirectory("code/app/.git")
        try fixture.makeDirectory("code/app/src")
        #expect(ProjectResolver(homeDirectory: fixture.home).resolve(cwd: path("code/app/src") + "/../src/").root == path("code/app"))
    }
}
