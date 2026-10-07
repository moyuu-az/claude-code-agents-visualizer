import Foundation
import Testing
@testable import AgentsVisualizerCore

/// Writes LevelDB files byte by byte, the way Chromium's Local Storage lays them out.
enum LevelDBFile {
    enum Op { case put([UInt8], [UInt8]), delete([UInt8]) }

    static func varint(_ value: Int) -> [UInt8] {
        var value = UInt64(value), bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        return bytes + [UInt8(value)]
    }

    static func fixed(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// One write batch per element; each batch's first operation gets `sequence`.
    static func log(_ batches: [(sequence: UInt64, ops: [Op])]) -> [UInt8] {
        var file: [UInt8] = []
        for batch in batches {
            var body = fixed(batch.sequence, 8) + fixed(UInt64(batch.ops.count), 4)
            for op in batch.ops {
                switch op {
                case let .put(key, value): body += [1] + varint(key.count) + key + varint(value.count) + value
                case let .delete(key): body += [0] + varint(key.count) + key
                }
            }
            file += record(body, blockOffset: file.count)
        }
        return file
    }

    /// Splits `data` into FIRST/MIDDLE/LAST fragments across 32 KiB blocks like LevelDB's log writer.
    private static func record(_ data: [UInt8], blockOffset start: Int) -> [UInt8] {
        let blockSize = 32768
        var out: [UInt8] = [], rest = data[...], first = true
        while true {
            let left = blockSize - (start + out.count) % blockSize
            if left < 7 { out += [UInt8](repeating: 0, count: left); continue }
            let fragment = rest.prefix(left - 7)
            rest = rest.dropFirst(fragment.count)
            let type: UInt8 = first && rest.isEmpty ? 1 : first ? 2 : rest.isEmpty ? 4 : 3
            out += [0, 0, 0, 0] + fixed(UInt64(fragment.count), 2) + [type] + fragment
            first = false
            if rest.isEmpty { return out }
        }
    }

    /// A table with one data block per element of `blocks`; `compress` stores the blocks snappy-encoded.
    static func table(_ blocks: [[(key: [UInt8], sequence: UInt64, value: [UInt8]?)]], compress: Bool = false) -> [UInt8] {
        var file: [UInt8] = [], index: [(key: [UInt8], value: [UInt8])] = []
        func append(_ entries: [(key: [UInt8], value: [UInt8])], compressed: Bool) -> [UInt8] {
            var contents = block(entries)
            if compressed { contents = snappyLiterals(contents) }
            let handle = varint(file.count) + varint(contents.count)
            file += contents + [compressed ? 1 : 0, 0, 0, 0, 0]
            return handle
        }
        for entries in blocks {
            let internalEntries = entries.map { ($0.key + fixed($0.sequence << 8 | ($0.value == nil ? 0 : 1), 8), $0.value ?? []) }
            index.append((internalEntries.last?.0 ?? [], append(internalEntries, compressed: compress)))
        }
        let meta = append([], compressed: false)
        let indexHandle = append(index, compressed: compress)
        var footer = meta + indexHandle
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        return file + footer + fixed(0xdb47_7524_8b80_fb57, 8)
    }

    /// Block entries with no key sharing and a single restart point.
    private static func block(_ entries: [(key: [UInt8], value: [UInt8])]) -> [UInt8] {
        entries.flatMap { [0] + varint($0.key.count) + varint($0.value.count) + $0.key + $0.value } + fixed(0, 4) + fixed(1, 4)
    }

    /// Valid snappy that encodes everything as literals of at most 60 bytes.
    static func snappyLiterals(_ data: [UInt8]) -> [UInt8] {
        var out = varint(data.count), rest = data[...]
        while !rest.isEmpty {
            let chunk = rest.prefix(60)
            rest = rest.dropFirst(chunk.count)
            out += [UInt8(chunk.count - 1) << 2] + chunk
        }
        return out
    }

    /// Chromium Local Storage key/value framing for `https://claude.ai`.
    static func localStorageKey(_ name: String) -> [UInt8] { Array("_https://claude.ai".utf8) + [0, 1] + Array(name.utf8) }
    static func latin1(_ value: String) -> [UInt8] { [1] + Array(value.utf8) }
    static func utf16(_ value: String) -> [UInt8] { [0] + value.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }

    static func unreadValue(_ ids: [String], explicit: [String] = []) -> String {
        Fixture.json(["state": ["unreadIds": ids, "explicitUnreadIds": explicit], "version": 0])
    }
}

@Suite struct LevelDBTests {
    let key = Array("k".utf8)

    @Test func snappyDecodesLiteralsAndEveryCopyForm() {
        // "abc", then copy-1 (9 bytes, offset 3), copy-2 (4 bytes, offset 12), copy-4 (2 bytes, offset 1).
        let compressed: [UInt8] = [18, 0x08, 97, 98, 99, 0x15, 3, 0x0e, 12, 0, 0x07, 1, 0, 0, 0]
        let expected = Array("abcabcabcabc".utf8) + Array("abca".utf8) + Array("aa".utf8)
        #expect(LevelDB.snappyDecompress(compressed[...]) == expected)
    }

    @Test func snappyDecodesLongLiterals() {
        let data = (0..<200).map { UInt8($0) }
        let compressed = LevelDBFile.varint(200) + [60 << 2, 199] + data
        #expect(LevelDB.snappyDecompress(compressed[...]) == data)
    }

    @Test func snappyRejectsMalformedInput() {
        #expect(LevelDB.snappyDecompress([3, 0x08, 97][...]) == nil)  // literal runs past the end
        #expect(LevelDB.snappyDecompress([4, 0x08, 97, 98, 99, 0x01, 9][...]) == nil)  // copy before the start
        #expect(LevelDB.snappyDecompress([2, 0x08, 97, 98, 99][...]) == nil)  // longer than declared
        #expect(LevelDB.snappyDecompress([5, 0x08, 97, 98, 99][...]) == nil)  // shorter than declared
        #expect(LevelDB.snappyDecompress([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f][...]) == nil)
        #expect(LevelDB.snappyDecompress([][...]) == nil)
    }

    @Test func logKeepsTheLastWriteOfTheKey() {
        let file = LevelDBFile.log([
            (5, [.put(key, [1]), .put(Array("other".utf8), [9])]),
            (7, [.put(Array("other".utf8), [8]), .put(key, [2])]),
        ])
        #expect(LevelDB.newest(key, inLog: file) == .init(sequence: 8, value: [2]))
    }

    @Test func logReportsDeletions() {
        let file = LevelDBFile.log([(5, [.put(key, [1])]), (6, [.delete(key)])])
        #expect(LevelDB.newest(key, inLog: file) == .init(sequence: 6, value: nil))
    }

    @Test func logReassemblesRecordsSpanningBlocks() {
        let big = [UInt8](repeating: 7, count: 70_000)
        let file = LevelDBFile.log([(1, [.put(Array("pad".utf8), [UInt8](repeating: 0, count: 32_000))]), (2, [.put(key, big)])])
        #expect(file.count > 2 * 32768)
        #expect(LevelDB.newest(key, inLog: file) == .init(sequence: 2, value: big))
    }

    @Test func truncatedLogKeepsCompleteRecords() {
        let file = LevelDBFile.log([(5, [.put(key, [1])]), (6, [.put(key, [2])])])
        #expect(LevelDB.newest(key, inLog: Array(file.dropLast(1))) == .init(sequence: 5, value: [1]))
        #expect(LevelDB.newest(key, inLog: []) == nil)
        #expect(LevelDB.newest(key, inLog: [UInt8](repeating: 0xff, count: 100)) == nil)
    }

    @Test(arguments: [false, true])
    func tableFindsTheKeyInAnyBlock(compress: Bool) {
        let file = LevelDBFile.table([
            [(Array("a".utf8), 3, [1])],
            [(key, 9, Array("value".utf8)), (Array("z".utf8), 4, [2])],
        ], compress: compress)
        #expect(LevelDB.newest(key, inTable: file) == .init(sequence: 9, value: Array("value".utf8)))
        #expect(LevelDB.newest(Array("missing".utf8), inTable: file) == nil)
    }

    @Test func tableKeepsTheHighestSequenceAndDeletions() {
        let file = LevelDBFile.table([[(key, 9, nil), (key, 4, [1])]])
        #expect(LevelDB.newest(key, inTable: file) == .init(sequence: 9, value: nil))
    }

    @Test func tableUndoesKeyPrefixSharing() {
        // The second key stores only what follows the first byte it shares with the first key.
        let internalKey = key + LevelDBFile.fixed(5 << 8 | 1, 8)
        let first = Array("kx".utf8) + LevelDBFile.fixed(1 << 8 | 1, 8)
        var block: [UInt8] = [0] + LevelDBFile.varint(first.count) + [1] + first + [0]
        block += [1] + LevelDBFile.varint(internalKey.count - 1) + [1] + internalKey.dropFirst() + [42]
        block += LevelDBFile.fixed(0, 4) + LevelDBFile.fixed(1, 4)
        #expect(LevelDB.blockEntries(block[...])?.last.map { Array($0.key) } == internalKey)
    }

    @Test func malformedTablesYieldNothing() {
        let good = LevelDBFile.table([[(key, 9, [1])]])
        #expect(LevelDB.newest(key, inTable: good) != nil)
        #expect(LevelDB.newest(key, inTable: Array(good.dropLast())) == nil)  // bad magic
        #expect(LevelDB.newest(key, inTable: Array(good.suffix(48))) == nil)  // handles point outside the file
        #expect(LevelDB.newest(key, inTable: []) == nil)
        var unknownCompression = good
        unknownCompression[good.count - 48 - 5] = 9  // the index block's type byte, just before its checksum and the footer
        #expect(LevelDB.newest(key, inTable: unknownCompression) == nil)
    }
}

@Suite struct DesktopUnreadStoreTests {
    let fixture: Fixture
    init() throws { fixture = try Fixture() }

    private let directory = "Library/Application Support/Claude/Local Storage/leveldb"
    private let unreadKey = LevelDBFile.localStorageKey("epitaxy-unread-v1")

    private func store() -> DesktopUnreadStore {
        DesktopUnreadStore(directory: fixture.environment().desktopLocalStorageDirectory)
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws {
        try fixture.makeDirectory(directory)
        try Data(bytes).write(to: fixture.url("\(directory)/\(name)"))
    }

    @Test func readsUnreadAndExplicitlyUnreadIds() throws {
        try write("000003.log", LevelDBFile.log([(1, [.put(unreadKey, LevelDBFile.latin1(
            LevelDBFile.unreadValue(["local_a", "local_b"], explicit: ["local_c"])))])]))
        #expect(store().load() == ["local_a", "local_b", "local_c"])
    }

    @Test func decodesUTF16Values() throws {
        try write("000003.log", LevelDBFile.log([(1, [.put(unreadKey, LevelDBFile.utf16(LevelDBFile.unreadValue(["local_é"])))])]))
        #expect(store().load() == ["local_é"])
    }

    @Test func newestEntryWinsAcrossLogAndTables() throws {
        try write("000005.ldb", LevelDBFile.table([[(unreadKey, 10, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_old"])))]], compress: true))
        try write("000007.ldb", LevelDBFile.table([[(unreadKey, 30, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_new"])))]], compress: true))
        try write("000008.log", LevelDBFile.log([(20, [.put(unreadKey, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_mid"])))])]))
        #expect(store().load() == ["local_new"])
    }

    @Test func deletionClearsTheList() throws {
        try write("000005.ldb", LevelDBFile.table([[(unreadKey, 10, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_a"])))]]))
        try write("000006.log", LevelDBFile.log([(11, [.delete(unreadKey)])]))
        #expect(store().load().isEmpty)
    }

    @Test func picksUpChangesAndIgnoresOtherOrigins() throws {
        let store = store()
        #expect(store.load().isEmpty)  // no directory yet
        let otherOrigin = Array("_https://example.com".utf8) + [0, 1] + Array("epitaxy-unread-v1".utf8)
        try write("000003.log", LevelDBFile.log([(1, [
            .put(otherOrigin, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_x"]))),
            .put(unreadKey, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_a"]))),
        ])]))
        #expect(store.load() == ["local_a"])
        try write("000003.log", LevelDBFile.log([
            (1, [.put(unreadKey, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_a"])))]),
            (2, [.put(unreadKey, LevelDBFile.latin1(LevelDBFile.unreadValue([])))]),
        ]))
        #expect(store.load().isEmpty)
    }

    @Test(arguments: [
        "{", #"{"state":{"unreadIds":"local_a"}}"#, #"{"state":{"unreadIds":[1]}}"#, #"{"unreadIds":["local_a"]}"#, "",
    ])
    func malformedValuesYieldNothing(value: String) throws {
        try write("000003.log", LevelDBFile.log([(1, [.put(unreadKey, LevelDBFile.latin1(value))])]))
        #expect(store().load().isEmpty)
    }

    @Test func toleratesMissingExplicitList() throws {
        try write("000003.log", LevelDBFile.log([(1, [.put(unreadKey, LevelDBFile.latin1(#"{"state":{"unreadIds":["local_a"]}}"#))])]))
        #expect(store().load() == ["local_a"])
    }

    @Test func emptyValueYieldsNothing() throws {
        try write("000003.log", LevelDBFile.log([(1, [.put(unreadKey, [])])]))
        #expect(store().load().isEmpty)
    }

    @Test func corruptFilesAreSkipped() throws {
        try write("000003.log", [UInt8](repeating: 0xff, count: 64))
        try write("000004.ldb", [UInt8](repeating: 0x00, count: 64))
        try write("000005.log", LevelDBFile.log([(1, [.put(unreadKey, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_a"])))])]))
        #expect(store().load() == ["local_a"])
    }
}
