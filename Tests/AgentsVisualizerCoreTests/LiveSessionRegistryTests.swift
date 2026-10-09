import Foundation
import Testing
@testable import AgentsVisualizerCore

@Suite struct LiveSessionRegistryTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    private var directory: URL { fixture.claudeDirectory.appending(path: "sessions") }

    private func register(pid: Int32, _ fields: [String: Any]) throws {
        var object: [String: Any] = ["pid": pid, "startedAt": 1_791_282_935_969]
        object.merge(fields) { $1 }
        try fixture.writeJSON(".claude/sessions/\(pid).json", object)
    }

    @Test(arguments: [
        ("busy", SessionStatus.running), ("waiting", .needsInput), ("idle", .idle),
        ("compacting", .running),  // unknown values count as busy, like Claude Code itself
    ])
    func mapsStatus(raw: String, expected: SessionStatus) throws {
        try register(pid: 10, ["sessionId": "s", "status": raw])
        let records = LiveSessionRegistry.load(directory: directory) { _, _ in true }
        #expect(records["s"]?.sessionStatus == expected)
    }

    @Test func missingStatusMeansIdle() throws {
        try register(pid: 10, ["sessionId": "s"])
        #expect(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"]?.sessionStatus == .idle)
    }

    @Test func dropsDeadParkedSpareAndAnonymousRegistrations() throws {
        try register(pid: 1, ["sessionId": "dead"])
        try register(pid: 2, ["sessionId": "parked", "parkedJobId": "job"])
        try register(pid: 3, ["sessionId": "spare", "spare": true])
        try register(pid: 4, [:])
        try register(pid: 5, ["sessionId": "alive"])
        let records = LiveSessionRegistry.load(directory: directory) { pid, _ in pid != 1 }
        #expect(Set(records.keys) == ["alive"])
    }

    @Test func skipsMalformedAndForeignFiles() throws {
        try fixture.write(".claude/sessions/7.json", "{ not json")
        try fixture.write(".claude/sessions/8.json", #"{"sessionId":"no-pid"}"#)
        try fixture.write(".claude/sessions/9.0cb66f.key", #"{"peerToken":"x"}"#)
        try register(pid: 10, ["sessionId": "ok", "status": "busy"])
        let records = LiveSessionRegistry.load(directory: directory) { _, _ in true }
        #expect(Set(records.keys) == ["ok"])
    }

    @Test func toleratesWrongFieldTypes() throws {
        try register(pid: 10, ["sessionId": "s", "status": 42, "name": ["nested": true], "cwd": "/repo"])
        let record = try #require(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"])
        #expect(record.status == nil)
        #expect(record.name == nil)
        #expect(record.cwd == "/repo")
    }

    @Test func missingDirectoryYieldsNothing() {
        #expect(LiveSessionRegistry.load(directory: fixture.url("nope")) { _, _ in true }.isEmpty)
    }

    @Test func sameSessionInTwoProcessesKeepsMostRecentlyUpdated() throws {
        try register(pid: 10, ["sessionId": "s", "status": "idle", "statusUpdatedAt": 1_791_000_000_000])
        try register(pid: 11, ["sessionId": "s", "status": "busy", "statusUpdatedAt": 1_791_000_001_000])
        let record = try #require(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"])
        #expect(record.pid == 11)
        #expect(record.sessionStatus == .running)
    }

    /// Seen in the wild: a terminal session also opened in Claude for Mac. The terminal process kept working while the
    /// app's process, idle but updated more recently, hid it.
    @Test func sameSessionInTwoProcessesKeepsTheOneDoingWork() throws {
        try register(pid: 10, ["sessionId": "s", "status": "busy", "statusUpdatedAt": 1_791_000_000_000])
        try register(pid: 11, ["sessionId": "s", "status": "idle", "statusUpdatedAt": 1_791_000_001_000])
        try register(pid: 12, ["sessionId": "s", "status": "waiting", "statusUpdatedAt": 1_790_000_000_000])
        let record = try #require(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"])
        #expect(record.pid == 12)
        #expect(record.sessionStatus == .needsInput)
    }

    /// Work started by either process is still alive, so it must not look as if it predates the session's process.
    @Test func sameSessionInTwoProcessesStartedWithTheEarlierOne() throws {
        try register(pid: 10, ["sessionId": "s", "status": "idle", "startedAt": 1_790_000_000_000,
                               "statusUpdatedAt": 1_791_000_000_000])
        try register(pid: 11, ["sessionId": "s", "status": "idle", "startedAt": 1_790_500_000_000,
                               "statusUpdatedAt": 1_791_000_001_000])
        let record = try #require(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"])
        #expect(record.pid == 11)
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func passesRegistrationTimeToLivenessProbe() throws {
        try register(pid: 10, ["sessionId": "s", "startedAt": 1_700_000_000_000])
        nonisolated(unsafe) var seen: Date?
        _ = LiveSessionRegistry.load(directory: directory) { _, registeredAt in
            seen = registeredAt
            return true
        }
        #expect(seen == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test(arguments: [
        (nil as String?, "Named" as String?), ("user", "Named"), ("peer", "Named"), ("derived", nil), ("auto", nil),
    ])
    func displayNameOnlyForHumanNames(source: String?, expected: String?) throws {
        var fields: [String: Any] = ["sessionId": "s", "name": "Named"]
        if let source { fields["nameSource"] = source }
        try register(pid: 10, fields)
        #expect(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"]?.displayName == expected)
    }

    @Test(arguments: [
        ("interactive", "claude-desktop", SessionSurface.desktop), ("interactive", "local-agent", .desktop),
        ("interactive", "claude-vscode", .vscode), ("interactive", "cli", .terminal), ("bg", "cli", .background),
    ])
    func mapsSurface(kind: String, entrypoint: String, expected: SessionSurface) throws {
        try register(pid: 10, ["sessionId": "s", "kind": kind, "entrypoint": entrypoint])
        #expect(LiveSessionRegistry.load(directory: directory) { _, _ in true }["s"]?.surface == expected)
    }
}

@Suite struct ProcessProbeTests {
    @Test func currentProcessIsAlive() {
        #expect(ProcessProbe.isAlive(pid: getpid(), registeredAt: Date()))
        #expect(ProcessProbe.isAlive(pid: getpid(), registeredAt: nil))
    }

    @Test func processStartedAfterRegistrationIsAReusedPid() {
        // This test process started long after 2001, so it cannot own a registration from then.
        #expect(!ProcessProbe.isAlive(pid: getpid(), registeredAt: Date(timeIntervalSinceReferenceDate: 0)))
    }

    @Test(arguments: [Int32(0), -1, Int32.max])
    func invalidOrMissingPidIsDead(pid: Int32) {
        #expect(!ProcessProbe.isAlive(pid: pid, registeredAt: nil))
    }
}

@Suite struct ClaudeEnvironmentTests {
    @Test func defaultsToTheStandardLocations() {
        let env = ClaudeEnvironment.from(environment: [:])
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Compare paths, not URLs: directory URLs differ by a trailing slash depending on the Foundation version.
        #expect(env.claudeDirectory.path == home.appending(path: ".claude").path)
        #expect(env.desktopSessionsDirectory.path.hasSuffix("Library/Application Support/Claude/claude-code-sessions"))
    }

    @Test func honoursOverrides() {
        let env = ClaudeEnvironment.from(environment: [
            "CLAUDE_CONFIG_DIR": "/tmp/claude-config", "AGENTS_VISUALIZER_DESKTOP_SESSIONS_DIR": "~/desktop-copy",
        ])
        #expect(env.claudeDirectory.path == "/tmp/claude-config")
        #expect(env.desktopSessionsDirectory.path == FileManager.default.homeDirectoryForCurrentUser.appending(path: "desktop-copy").path)
    }

    @Test func emptyOverrideIsIgnored() {
        #expect(ClaudeEnvironment.from(environment: ["CLAUDE_CONFIG_DIR": ""]).claudeDirectory.lastPathComponent == ".claude")
    }
}
