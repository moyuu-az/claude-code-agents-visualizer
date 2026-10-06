import Foundation
import Testing
@testable import AgentsVisualizerCore

@Suite struct DesktopSessionStoreTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    private let base = "Library/Application Support/Claude/claude-code-sessions"

    @discardableResult
    private func writeSession(_ id: String, account: String = "acct", org: String = "org", _ fields: [String: Any]) throws -> URL {
        var object: [String: Any] = ["sessionId": id]
        object.merge(fields) { $1 }
        return try fixture.writeJSON("\(base)/\(account)/\(org)/\(id).json", object)
    }

    @Test func decodesTheFieldsTheDashboardUses() throws {
        try writeSession("local_a", [
            "cliSessionId": "cli-a", "cwd": "/repo", "title": "Fix login", "isArchived": false,
            "createdAt": 1_791_000_000_000, "lastActivityAt": 1_791_000_500_000, "branch": "feature/x",
            "sshConfig": ["sshHost": "build-box"],
            "prs": [["prNumber": 12, "url": "https://github.com/o/r/pull/12", "state": "OPEN"]],
            "remoteMcpServersConfig": [["huge": "payload"]],
        ])
        let record = try #require(DesktopSessionStore(root: fixture.desktopDirectory).load()["cli-a"])
        #expect(record.sessionId == "local_a")
        #expect(record.title == "Fix login")
        #expect(record.cwd == "/repo")
        #expect(record.branch == "feature/x")
        #expect(record.sshHost == "build-box")
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(record.lastActivityAt == Date(timeIntervalSince1970: 1_791_000_500))
        #expect(record.pullRequests == [PullRequestRef(number: 12, url: URL(string: "https://github.com/o/r/pull/12")!, state: "OPEN")])
    }

    @Test func rejectsNonWebPullRequestLinksAndDuplicates() throws {
        try writeSession("local_a", ["cliSessionId": "cli-a", "prs": [
            ["prNumber": 1, "url": "javascript:alert(1)"],
            ["prNumber": 2, "url": "file:///etc/passwd"],
            ["prNumber": 3, "url": "https://github.com/o/r/pull/3"],
            ["prNumber": 3, "url": "https://github.com/o/r/pull/3"],
            ["url": "https://github.com/o/r/pull/4"],
        ]])
        let record = try #require(DesktopSessionStore(root: fixture.desktopDirectory).load()["cli-a"])
        #expect(record.pullRequests.map(\.number) == [3])
    }

    @Test func toleratesSchemaDrift() throws {
        try writeSession("local_a", ["cliSessionId": "cli-a", "title": 123, "isArchived": "yes", "prs": "none", "sshConfig": 1])
        let record = try #require(DesktopSessionStore(root: fixture.desktopDirectory).load()["cli-a"])
        #expect(record.title == nil)
        #expect(record.isArchived == false)
        #expect(record.pullRequests.isEmpty)
        #expect(record.sshHost == nil)
    }

    @Test func readsEveryAccountAndOrganisation() throws {
        try writeSession("local_a", account: "a1", org: "o1", ["cliSessionId": "cli-a"])
        try writeSession("local_b", account: "a2", org: "o2", ["cliSessionId": "cli-b"])
        #expect(Set(DesktopSessionStore(root: fixture.desktopDirectory).load().keys) == ["cli-a", "cli-b"])
    }

    @Test func ignoresUnrelatedAndBrokenFiles() throws {
        try writeSession("local_ok", ["cliSessionId": "cli-ok"])
        try writeSession("local_nocli", [:])
        try fixture.write("\(base)/acct/org/local_broken.json", "{")
        try fixture.writeJSON("\(base)/acct/org/backlog/tasks.json", ["sessionId": "x", "cliSessionId": "cli-x"])
        try fixture.writeJSON("\(base)/acct/org/other.json", ["sessionId": "y", "cliSessionId": "cli-y"])
        #expect(Set(DesktopSessionStore(root: fixture.desktopDirectory).load().keys) == ["cli-ok"])
    }

    @Test func missingRootYieldsNothing() {
        #expect(DesktopSessionStore(root: fixture.url("missing")).load().isEmpty)
    }

    @Test func duplicateCliIdKeepsMostRecentActivity() throws {
        try writeSession("local_old", ["cliSessionId": "cli", "title": "Old", "lastActivityAt": 1000])
        try writeSession("local_new", ["cliSessionId": "cli", "title": "New", "lastActivityAt": 2000])
        #expect(DesktopSessionStore(root: fixture.desktopDirectory).load()["cli"]?.title == "New")
    }

    @Test func picksUpEditsAndDeletionsAcrossRefreshes() throws {
        let store = DesktopSessionStore(root: fixture.desktopDirectory)
        let url = try writeSession("local_a", ["cliSessionId": "cli-a", "title": "Before"])
        #expect(store.load()["cli-a"]?.title == "Before")
        // Different size guarantees a new stamp even within the same mtime second.
        try writeSession("local_a", ["cliSessionId": "cli-a", "title": "After the rename"])
        #expect(store.load()["cli-a"]?.title == "After the rename")
        try FileManager.default.removeItem(at: url)
        #expect(store.load().isEmpty)
    }
}
