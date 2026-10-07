import Foundation

/// Just enough of LevelDB's on-disk format to find the newest value of one key: the write-ahead log (`*.log`) and
/// table files (`*.ldb`, blocks optionally snappy-compressed). Chromium keeps a web view's Local Storage this way.
///
/// Files come from another app and may be half-written while we read them, so every read is bounds-checked and a
/// malformed record or block ends the scan of that file instead of trapping. Checksums are not verified: a torn
/// write shows up as a length that runs past the data, and a value that fails to decode is ignored by the caller.
enum LevelDB {
    struct Entry: Equatable {
        /// Global write order across all files of the database; the highest one is the current value.
        let sequence: UInt64
        /// `nil` when the key was deleted.
        let value: [UInt8]?
    }

    // MARK: Log

    private static let logBlockSize = 32768
    private static let logHeaderSize = 7

    static func newest(_ key: [UInt8], inLog file: [UInt8]) -> Entry? {
        var newest: Entry?
        for record in logRecords(file) {
            var reader = ByteReader(record[...])
            // A write batch: base sequence, operation count, then the operations, numbered from the base.
            guard let base = reader.fixed(8), let count = reader.fixed(4) else { continue }
            var index: UInt64 = 0
            while index < count, let tag = reader.byte(), let keyLength = reader.varint(), let opKey = reader.take(keyLength) {
                let value: [UInt8]?
                if tag == 1 {
                    guard let length = reader.varint(), let bytes = reader.take(length) else { break }
                    value = Array(bytes)
                } else if tag == 0 {
                    value = nil
                } else {
                    break  // unknown operation: the rest of the batch cannot be framed
                }
                let (sequence, overflow) = base.addingReportingOverflow(index)
                if !overflow, opKey.elementsEqual(key), sequence >= (newest?.sequence ?? 0) {
                    newest = Entry(sequence: sequence, value: value)
                }
                index += 1
            }
        }
        return newest
    }

    /// Reassembles records split across 32 KiB blocks (FULL = 1, FIRST = 2, MIDDLE = 3, LAST = 4).
    private static func logRecords(_ file: [UInt8]) -> [[UInt8]] {
        var records: [[UInt8]] = []
        var pending: [UInt8]?
        var position = 0
        while file.count - position >= logHeaderSize {
            let blockLeft = logBlockSize - position % logBlockSize
            if blockLeft < logHeaderSize {  // block trailer padding
                position += blockLeft
                continue
            }
            let length = Int(file[position + 4]) | Int(file[position + 5]) << 8
            let type = file[position + 6]
            let start = position + logHeaderSize
            guard length <= blockLeft - logHeaderSize, length <= file.count - start else { break }  // torn tail
            let fragment = file[start..<start + length]
            position = start + length
            switch type {
            case 1: records.append(Array(fragment)); pending = nil
            case 2: pending = Array(fragment)
            case 3: pending? += fragment
            case 4:
                if let first = pending { records.append(first + fragment) }
                pending = nil
            default:  // zero-filled or corrupt: LevelDB skips to the next block too
                pending = nil
                position += (logBlockSize - position % logBlockSize) % logBlockSize
            }
        }
        return records
    }

    // MARK: Table

    private static let tableMagic: UInt64 = 0xdb47_7524_8b80_fb57
    private static let footerSize = 48

    static func newest(_ key: [UInt8], inTable file: [UInt8]) -> Entry? {
        guard file.count >= footerSize else { return nil }
        var footer = ByteReader(file[(file.count - footerSize)...])
        var magic = ByteReader(file[(file.count - 8)...])
        guard magic.fixed(8) == tableMagic,
              footer.varint() != nil, footer.varint() != nil,  // metaindex handle: filters, unused here
              let indexOffset = footer.varint(), let indexSize = footer.varint(),
              let index = block(in: file, offset: indexOffset, size: indexSize).flatMap(blockEntries)
        else { return nil }

        var newest: Entry?
        for (_, handle) in index {
            var reader = ByteReader(handle)
            guard let offset = reader.varint(), let size = reader.varint(),
                  let entries = block(in: file, offset: offset, size: size).flatMap(blockEntries)
            else { continue }
            for (internalKey, value) in entries where internalKey.count >= 8 {
                // Internal key = user key + little-endian (sequence << 8 | type); type 1 = value, 0 = deletion.
                var trailer = ByteReader(internalKey[(internalKey.count - 8)...])
                guard let tag = trailer.fixed(8), internalKey.dropLast(8).elementsEqual(key),
                      tag >> 8 >= (newest?.sequence ?? 0)
                else { continue }
                switch tag & 0xff {
                case 1: newest = Entry(sequence: tag >> 8, value: Array(value))
                case 0: newest = Entry(sequence: tag >> 8, value: nil)
                default: continue
                }
            }
        }
        return newest
    }

    /// Block contents at a handle; each block is followed by a compression type byte and a 4-byte checksum.
    private static func block(in file: [UInt8], offset: Int, size: Int) -> ArraySlice<UInt8>? {
        guard offset <= file.count, size <= file.count - offset - 5 else { return nil }
        let contents = file[offset..<offset + size]
        switch file[offset + size] {
        case 0: return contents
        case 1: return snappyDecompress(contents).map { $0[...] }
        default: return nil
        }
    }

    /// Entries of a block: prefix-compressed keys, then the restart offsets and their count (both fixed32).
    static func blockEntries(_ block: ArraySlice<UInt8>) -> [(key: [UInt8], value: ArraySlice<UInt8>)]? {
        var countReader = ByteReader(block.suffix(4))
        guard block.count >= 4, let restarts = countReader.fixed(4),
              restarts <= UInt64((block.count - 4) / 4)
        else { return nil }
        var reader = ByteReader(block.prefix(block.count - 4 - Int(restarts) * 4))
        var entries: [(key: [UInt8], value: ArraySlice<UInt8>)] = []
        var key: [UInt8] = []
        while !reader.isAtEnd {
            guard let shared = reader.varint(), let unshared = reader.varint(), let valueLength = reader.varint(),
                  shared <= key.count, let delta = reader.take(unshared), let value = reader.take(valueLength)
            else { return nil }
            key = Array(key.prefix(shared)) + delta
            entries.append((key, value))
        }
        return entries
    }

    // MARK: Snappy

    /// Snappy raw format: a varint length, then literals and back-references into the output.
    static func snappyDecompress(_ input: ArraySlice<UInt8>) -> [UInt8]? {
        var reader = ByteReader(input)
        // A table block is a few KiB; refusing absurd lengths keeps a corrupt header from allocating gigabytes.
        guard let length = reader.varint(), length <= 64 << 20 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(length)
        while !reader.isAtEnd {
            guard let tag = reader.byte() else { return nil }
            let copyLength: Int, offset: Int
            switch tag & 3 {
            case 0:
                var literalLength = Int(tag >> 2)
                if literalLength >= 60 {
                    guard let extended = reader.fixed(literalLength - 59) else { return nil }
                    literalLength = Int(extended)
                }
                guard literalLength < length - output.count, let literal = reader.take(literalLength + 1) else { return nil }
                output += literal
                continue
            case 1:
                guard let low = reader.byte() else { return nil }
                copyLength = Int(tag >> 2 & 7) + 4
                offset = Int(tag >> 5) << 8 | Int(low)
            case 2:
                guard let value = reader.fixed(2) else { return nil }
                copyLength = Int(tag >> 2) + 1
                offset = Int(value)
            default:
                guard let value = reader.fixed(4) else { return nil }
                copyLength = Int(tag >> 2) + 1
                offset = Int(value)
            }
            guard offset > 0, offset <= output.count, copyLength <= length - output.count else { return nil }
            // Byte by byte: the source may overlap what is being written (offset < length repeats a pattern).
            for _ in 0..<copyLength { output.append(output[output.count - offset]) }
        }
        return output.count == length ? output : nil
    }
}

/// Bounds-checked little-endian reader; every accessor returns `nil` instead of reading past the end.
private struct ByteReader {
    private var rest: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { rest = bytes }

    var isAtEnd: Bool { rest.isEmpty }

    mutating func byte() -> UInt8? { rest.popFirst() }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, count <= rest.count else { return nil }
        defer { rest = rest.dropFirst(count) }
        return rest.prefix(count)
    }

    mutating func fixed(_ count: Int) -> UInt64? {
        guard count <= 8, let bytes = take(count) else { return nil }
        return bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// LevelDB varint (7 bits per byte, low first), as a non-negative `Int`.
    mutating func varint() -> Int? {
        var result: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard let byte = byte() else { return nil }
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return Int(exactly: result) }
        }
        return nil
    }
}
