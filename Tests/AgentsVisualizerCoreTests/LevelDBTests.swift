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

    /// A block tail too short for a header is zero padding; a tail of exactly one header holds an empty FIRST
    /// fragment. The record after either must still be found.
    @Test(arguments: 0...8)
    func logRecordEndingNearABlockBoundary(tail: Int) {
        // The pad record is 27 bytes of framing (header, batch header, tag, lengths, "pad") plus its value.
        let file = LevelDBFile.log([(1, [.put(Array("pad".utf8), [UInt8](repeating: 0, count: 32_741 - tail))]), (2, [.put(key, [42])])])
        if (1...6).contains(tail) { #expect(file[(32768 - tail)..<32768].allSatisfy { $0 == 0 }) }
        if tail == 7 { #expect(Array(file[32761..<32768]) == [0, 0, 0, 0, 0, 0, 2]) }
        #expect(LevelDB.newest(key, inLog: file) == .init(sequence: 2, value: [42]))
        #expect(LevelDB.newest(Array("pad".utf8), inLog: file)?.sequence == 1)
    }

    /// Claude may be appending while we read, so the file can end anywhere. Whatever the cut, the result is a write
    /// that really happened (never a half-read one), and it only moves forward as more of the file arrives.
    @Test(arguments: [false, true])
    func everyTornTailOfALogYieldsAWrittenEntry(spanningBlocks: Bool) {
        let big = [UInt8](repeating: 3, count: spanningBlocks ? 70_000 : 300)
        let file = LevelDBFile.log([
            (5, [.put(key, [1]), .put(Array("other".utf8), [9])]), (7, [.delete(key)]), (8, [.put(key, big)]),
            (9, [.put(Array("other".utf8), [1])]), (10, [.put(key, [2])]),
        ])
        let written: [LevelDB.Entry?] = [nil, .init(sequence: 5, value: [1]), .init(sequence: 7, value: nil),
                                         .init(sequence: 8, value: big), .init(sequence: 10, value: [2])]
        var previous: UInt64 = 0
        // Every byte for the small file; a stride for the one spanning three blocks (cuts inside FIRST/MIDDLE/LAST).
        for length in stride(from: 0, through: file.count, by: spanningBlocks ? 61 : 1) {
            let entry = LevelDB.newest(key, inLog: Array(file.prefix(length)))
            #expect(written.contains(entry), "cut at \(length)")
            #expect((entry?.sequence ?? 0) >= previous, "cut at \(length)")
            previous = entry?.sequence ?? 0
        }
        #expect(LevelDB.newest(key, inLog: file) == written.last)
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

    /// A table being written by a compaction has no footer yet; one missing its head has handles that point elsewhere.
    /// Neither may invent a value.
    @Test(arguments: [false, true])
    func everyPartOfATableYieldsNothingOrTheValue(compress: Bool) {
        let file = LevelDBFile.table([[(Array("a".utf8), 3, [1])], [(key, 9, Array("value".utf8)), (Array("z".utf8), 4, [2])]],
                                     compress: compress)
        let expected = LevelDB.Entry(sequence: 9, value: Array("value".utf8))
        for length in 0..<file.count {
            #expect(LevelDB.newest(key, inTable: Array(file.prefix(length))) == nil, "first \(length) bytes")
            let tail = LevelDB.newest(key, inTable: Array(file.suffix(length)))
            #expect(tail == nil || tail == expected, "last \(length) bytes")
        }
        #expect(LevelDB.newest(key, inTable: file) == expected)
    }

    /// Whatever the bytes, reading ends without trapping (index out of range, negative length, integer overflow): the
    /// test process would crash otherwise. Seeded so that a failure reproduces.
    @Test func corruptedFilesNeverTrap() {
        var random = SplitMix64(seed: 0x5eed)
        let samples = [
            LevelDBFile.log([(5, [.put(key, [1]), .delete(Array("other".utf8))]), (7, [.put(key, [UInt8](repeating: 3, count: 300))])]),
            LevelDBFile.table([[(Array("a".utf8), 3, [1])], [(key, 9, [2]), (Array("z".utf8), 4, nil)]]),
            LevelDBFile.table([[(Array("a".utf8), 3, [1])], [(key, 9, [2]), (Array("z".utf8), 4, nil)]], compress: true),
            [18, 0x08, 97, 98, 99, 0x15, 3, 0x0e, 12, 0, 0x07, 1, 0, 0, 0],  // snappy with every tag kind
        ]
        for _ in 0..<3000 {
            var bytes = samples[Int(random.next() % UInt64(samples.count))]
            for _ in 0...random.next() % 3 { bytes = corrupt(bytes, &random) }
            _ = LevelDB.newest(key, inLog: bytes)
            _ = LevelDB.newest(key, inTable: bytes)
            _ = LevelDB.snappyDecompress(bytes[...])
            _ = LevelDB.blockEntries(bytes[...])
            _ = DesktopUnreadStore.decode(bytes)
        }
    }

    private func corrupt(_ input: [UInt8], _ random: inout SplitMix64) -> [UInt8] {
        var bytes = input
        func index() -> Int { Int(random.next() % UInt64(bytes.count)) }
        guard !bytes.isEmpty else { return (0..<random.next() % 64).map { _ in UInt8(truncatingIfNeeded: random.next()) } }
        switch random.next() % 5 {
        case 0: bytes.removeLast(index())
        case 1: for _ in 0...random.next() % 8 { bytes[index()] ^= 1 << (random.next() % 8) }
        // Values that sit on varint, length and type boundaries.
        case 2: for _ in 0...random.next() % 8 { bytes[index()] = [0x00, 0x01, 0x7f, 0x80, 0xff][Int(random.next() % 5)] }
        case 3: bytes.insert(contentsOf: (0..<random.next() % 16).map { _ in UInt8(truncatingIfNeeded: random.next()) }, at: index())
        default: bytes = (0..<random.next() % 256).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        }
        return bytes
    }
}

/// Deterministic generator for the corruption test.
private struct SplitMix64: RandomNumberGenerator {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed &+= 0x9e37_79b9_7f4a_7c15
        var z = seed
        z = (z ^ z >> 30) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ z >> 27) &* 0x94d0_49bb_1331_11eb
        return z ^ z >> 31
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

    /// A compaction can drop the key altogether (a deletion merged with the value it hides) and delete the files
    /// that held it. What was cached for a file that is gone must not bring the old list back.
    @Test func filesRemovedByACompactionStopCounting() throws {
        let store = store()
        try write("000005.ldb", LevelDBFile.table([[(unreadKey, 30, LevelDBFile.latin1(LevelDBFile.unreadValue(["local_a"])))]]))
        #expect(store.load() == ["local_a"])
        try FileManager.default.removeItem(at: fixture.url("\(directory)/000005.ldb"))
        try write("000009.ldb", LevelDBFile.table([[(Array("other".utf8), 40, [1])]]))
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
