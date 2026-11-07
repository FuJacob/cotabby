import Foundation

/// File overview:
/// Reads every live key/value of a LevelDB database folder, in place and read-only, for the Teams
/// cache reader (Chromium stores IndexedDB in LevelDB).
///
/// Why its own type: LevelDB is a storage format with its own rules (log files, sorted tables,
/// sequence numbers, deletions) that has nothing to do with IndexedDB or Teams. Keeping it here
/// lets `IndexedDBReader` see a plain "key -> newest value" snapshot and lets the tests pin the
/// file formats with hand-built bytes.
///
/// How a LevelDB folder holds data (https://github.com/google/leveldb/blob/main/doc):
/// - `NNNNNN.log`: the write-ahead log of recent writes, in 32 KB blocks. Each block holds record
///   fragments (7-byte header: CRC, length, type FULL/FIRST/MIDDLE/LAST); joined fragments form a
///   write batch: sequence number (u64 LE), count (u32 LE), then `count` entries, each a type byte
///   (1 put, 0 delete), a varint-prefixed key and, for puts, a varint-prefixed value. Entry `i` of
///   a batch has sequence number `sequence + i`.
/// - `NNNNNN.ldb` (or `.sst`): immutable sorted tables. A 48-byte footer ends in the magic number
///   and points at the index block, whose entries point at the data blocks. Every block is followed
///   by a 5-byte trailer (compression type: 0 none, 1 Snappy; then a CRC). Inside a block, keys are
///   prefix-compressed against the previous key (shared length, unshared length, value length,
///   unshared key bytes, value), and a restart array at the end marks where that chain restarts.
///   Table keys are "internal keys": the user key plus 8 bytes `sequence << 8 | type`.
///
/// The same key can appear in several files (a newer write in the log, older ones in tables not yet
/// compacted). The newest version is the one with the highest sequence number, and a deletion as
/// the newest version means the key is gone. This reader resolves exactly that, so callers see the
/// database as LevelDB itself would.
///
/// Reading a live database: Teams keeps writing while Cotabby reads, and a compaction can delete a
/// table between listing the folder and opening the file. Each file is read whole into memory as
/// soon as it is opened (so it cannot change under the parser); if one vanished, the folder is
/// listed again and read once more (the compaction's output then holds the data), and a file that
/// vanishes on that second pass too is skipped. A log's unfinished tail (a batch Teams is writing
/// right now) is ignored. Nothing here ever writes, locks or creates a file in the folder.
///
/// Ported from CCL Forensics' `ccl_leveldb` (MIT, see THIRD_PARTY_LICENSES.md), with the newest-
/// version resolution added (the original yields every version of every key) and bounds checks on
/// every length so a corrupt file throws instead of crashing.
nonisolated struct LevelDBReader {
    enum ReadError: LocalizedError, Equatable {
        case notADirectory(String)
        case notPermitted(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notADirectory(let path): return "\(path) is not a LevelDB folder."
            case .notPermitted(let path): return "Cotabby is not allowed to read \(path). Grant Full Disk Access."
            case .corrupt(let detail): return "The cache is damaged: \(detail)"
            }
        }
    }

    /// The database as LevelDB would present it: each live user key with its newest value.
    struct Snapshot {
        let entries: [[UInt8]: ArraySlice<UInt8>]
        /// How many key versions were read across all files, before resolution (for diagnostics).
        let versionsRead: Int
    }

    let folder: URL

    static let logBlockSize = 32 * 1024
    static let tableMagic: UInt64 = 0xdb47_7524_8b80_fb57
    static let tableFooterSize = 48
    static let blockTrailerSize = 5

    /// Reads every file of the folder. `keeping` limits the snapshot to the user keys it accepts:
    /// a Teams cache holds a hundred databases and only three matter, so filtering while reading
    /// keeps the snapshot (and the memory it holds) to those. Kept values are then copied out of
    /// their blocks, so each decompressed block is freed as soon as it has been walked.
    func read(keeping filter: ((ArraySlice<UInt8>) -> Bool)? = nil) throws -> Snapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReadError.notADirectory(folder.path)
        }
        for attempt in 0..<2 {
            var resolver = Resolver(filter: filter)
            var vanished = false
            for file in try dataFiles() {
                guard let bytes = try Self.readFile(file.url) else {
                    vanished = true
                    if attempt == 0 { break } else { continue }
                }
                switch file.kind {
                case .log: try Self.parseLog(bytes, into: &resolver)
                case .table: try Self.parseTable(bytes, name: file.url.lastPathComponent, into: &resolver)
                }
            }
            if !vanished || attempt == 1 {
                return Snapshot(entries: resolver.liveEntries(), versionsRead: resolver.versionsRead)
            }
        }
        preconditionFailure("unreachable: the second attempt always returns")
    }

    // MARK: - Files

    enum FileKind { case log, table }

    struct DataFile: Equatable {
        let url: URL
        let kind: FileKind
        let number: UInt64
    }

    /// The folder's log and table files, oldest first (LevelDB numbers files in creation order).
    /// `MANIFEST`, `CURRENT`, `LOCK` and `LOG` describe the database but hold no user data.
    func dataFiles() throws -> [DataFile] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            if Self.isPermissionError(error) { throw ReadError.notPermitted(folder.path) }
            throw error
        }
        return names.compactMap { name -> DataFile? in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt64(parts[0]) else { return nil }
            switch parts[1].lowercased() {
            case "log": return DataFile(url: folder.appendingPathComponent(name), kind: .log, number: number)
            case "ldb", "sst": return DataFile(url: folder.appendingPathComponent(name), kind: .table, number: number)
            default: return nil
            }
        }
        .sorted { $0.number < $1.number }
    }

    /// The whole file, or nil when it no longer exists (deleted by a compaction since the listing).
    static func readFile(_ url: URL) throws -> [UInt8]? {
        do {
            let data = try Data(contentsOf: url, options: .uncached)
            return [UInt8](data)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError { return nil }
            if isPermissionError(error) { throw ReadError.notPermitted(url.path) }
            throw error
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain
            && (underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES))
    }

    // MARK: - Resolution

    /// Keeps, per user key, the version with the highest sequence number seen so far.
    struct Resolver {
        private var newest: [[UInt8]: (sequence: UInt64, value: ArraySlice<UInt8>?)] = [:]
        private(set) var versionsRead = 0
        private let filter: ((ArraySlice<UInt8>) -> Bool)?

        init(filter: ((ArraySlice<UInt8>) -> Bool)? = nil) {
            self.filter = filter
        }

        /// `value` is nil for a deletion.
        mutating func add(key: ArraySlice<UInt8>, sequence: UInt64, value: ArraySlice<UInt8>?) {
            versionsRead += 1
            if let filter, !filter(key) { return }
            let key = Array(key)
            if let current = newest[key], current.sequence > sequence { return }
            // Unfiltered reads (tests) keep slices of the file or block; filtered ones copy, so the
            // block they came from is not kept alive by one small value.
            newest[key] = (sequence, filter == nil ? value : value.map { ArraySlice(Array($0)) })
        }

        func liveEntries() -> [[UInt8]: ArraySlice<UInt8>] {
            newest.compactMapValues(\.value)
        }
    }

    // MARK: - Log files

    /// Joins the fragments of each 32 KB block into write batches and adds their entries. Parsing
    /// stops at the first fragment that does not fit its block or breaks the FIRST/MIDDLE/LAST
    /// chain: in a log being written that is the unfinished tail, and nothing after it is valid.
    static func parseLog(_ bytes: [UInt8], into resolver: inout Resolver) throws {
        var assembler = LogBatchAssembler()
        var blockStart = 0
        while blockStart < bytes.count {
            let blockEnd = min(blockStart + logBlockSize, bytes.count)
            var position = blockStart
            // A block's last 6 or fewer bytes cannot hold a header and are zero padding.
            while blockEnd - position >= 7 {
                let length = Int(bytes[position + 4]) | Int(bytes[position + 5]) << 8
                let start = position + 7
                guard start + length <= blockEnd,
                      try assembler.accept(type: bytes[position + 6], fragment: bytes[start..<(start + length)],
                                           into: &resolver) else { return }
                position = start + length
            }
            blockStart += logBlockSize
        }
    }

    /// Joins a log's FULL / FIRST / MIDDLE / LAST fragments into whole write batches.
    private struct LogBatchAssembler {
        private var batch: [UInt8] = []
        private var inRecord = false

        /// Takes the next fragment, parsing each batch it completes. False when the fragment breaks
        /// the chain or is preallocated space (type 0): nothing after it is valid.
        mutating func accept(type: UInt8, fragment: ArraySlice<UInt8>, into resolver: inout Resolver) throws -> Bool {
            switch type {
            case 1: // FULL
                guard !inRecord else { return false }
                try parseBatch(fragment, into: &resolver)
            case 2: // FIRST
                guard !inRecord else { return false }
                batch = Array(fragment)
                inRecord = true
            case 3: // MIDDLE
                guard inRecord else { return false }
                batch.append(contentsOf: fragment)
            case 4: // LAST
                guard inRecord else { return false }
                batch.append(contentsOf: fragment)
                inRecord = false
                try parseBatch(batch[...], into: &resolver)
            default:
                return false
            }
            return true
        }
    }

    /// A write batch: sequence (u64 LE), count (u32 LE), then the entries. A batch cut short is
    /// skipped from the entry that does not fit; the entries before it are kept, as LevelDB's own
    /// recovery would not apply a torn batch at all but its complete entries are still the newest
    /// data Teams wrote.
    static func parseBatch(_ batch: ArraySlice<UInt8>, into resolver: inout Resolver) throws {
        var reader = ByteReader(batch)
        guard let sequence = reader.readUInt64LE(), let count = reader.readUInt32LE() else { return }
        // Wrapping: a damaged header's sequence near the top must not trap (`&+` below).
        for index in 0..<UInt64(count) {
            guard let type = reader.readByte(),
                  let keyLength = reader.readVarint32(),
                  let key = reader.read(Int(keyLength)) else { return }
            switch type {
            case 0:
                resolver.add(key: key, sequence: sequence &+ index, value: nil)
            case 1:
                guard let valueLength = reader.readVarint32(), let value = reader.read(Int(valueLength)) else { return }
                resolver.add(key: key, sequence: sequence &+ index, value: value)
            default:
                return
            }
        }
    }

    // MARK: - Table files

    static func parseTable(_ bytes: [UInt8], name: String, into resolver: inout Resolver) throws {
        guard bytes.count >= tableFooterSize else { throw ReadError.corrupt("\(name) is too short") }
        var magicReader = ByteReader(bytes[(bytes.count - 8)...])
        guard magicReader.readUInt64LE() == tableMagic else { throw ReadError.corrupt("\(name) has no table magic") }
        var footer = ByteReader(bytes[(bytes.count - tableFooterSize)...])
        // The meta-index handle (offset, size) comes first: filters and stats, not data.
        guard footer.readVarint64() != nil, footer.readVarint64() != nil,
              let indexOffset = footer.readVarint64(), let indexLength = footer.readVarint64() else {
            throw ReadError.corrupt("\(name) has a damaged footer")
        }
        let index = try readBlock(bytes, offset: indexOffset, length: indexLength, name: name)
        try forEachEntry(in: index, name: name) { _, handleBytes in
            var handle = ByteReader(handleBytes)
            guard let offset = handle.readVarint64(), let length = handle.readVarint64() else {
                throw ReadError.corrupt("\(name) has a damaged block handle")
            }
            let block = try readBlock(bytes, offset: offset, length: length, name: name)
            try forEachEntry(in: block, name: name) { internalKey, value in
                // Internal key = user key + 8 bytes (sequence << 8 | type), little-endian.
                guard internalKey.count >= 8 else { return }
                let split = internalKey.count - 8
                var trailer = ByteReader(internalKey[split...])
                let packed = trailer.readUInt64LE() ?? 0
                let isDeletion = packed & 0xFF == 0
                resolver.add(key: internalKey[..<split], sequence: packed >> 8, value: isDeletion ? nil : value)
            }
        }
    }

    /// One block's bytes, decompressed when its trailer says Snappy.
    static func readBlock(_ bytes: [UInt8], offset: UInt64, length: UInt64, name: String) throws -> [UInt8] {
        guard offset <= UInt64(bytes.count), length <= UInt64(bytes.count),
              Int(offset) + Int(length) + blockTrailerSize <= bytes.count else {
            throw ReadError.corrupt("\(name) points past its end")
        }
        let start = Int(offset)
        let end = start + Int(length)
        switch bytes[end] {
        case 0:
            return Array(bytes[start..<end])
        case 1:
            do {
                return try SnappyDecoder.decompress(bytes[start..<end])
            } catch {
                throw ReadError.corrupt("\(name) has a damaged compressed block")
            }
        default:
            throw ReadError.corrupt("\(name) uses an unknown compression (\(bytes[end]))")
        }
    }

    /// Walks a block's prefix-compressed entries in order, rebuilding each full key.
    static func forEachEntry(
        in block: [UInt8],
        name: String,
        _ body: (_ key: ArraySlice<UInt8>, _ value: ArraySlice<UInt8>) throws -> Void
    ) throws {
        guard block.count >= 4 else { throw ReadError.corrupt("\(name) has a block without restarts") }
        var tail = ByteReader(block[(block.count - 4)...])
        let restartCount = Int(tail.readUInt32LE() ?? 0)
        let restartsStart = block.count - (restartCount + 1) * 4
        guard restartCount <= block.count / 4, restartsStart >= 0 else {
            throw ReadError.corrupt("\(name) has a damaged restart array")
        }
        var reader = ByteReader(block[0..<restartsStart])
        var key: [UInt8] = []
        while !reader.isAtEnd {
            guard let shared = reader.readVarint32(), let unshared = reader.readVarint32(),
                  let valueLength = reader.readVarint32(), Int(shared) <= key.count,
                  let suffix = reader.read(Int(unshared)), let value = reader.read(Int(valueLength)) else {
                throw ReadError.corrupt("\(name) has a damaged block entry")
            }
            key.removeSubrange(Int(shared)...)
            key.append(contentsOf: suffix)
            try body(key[...], value)
        }
    }
}

/// A bounds-checked cursor over bytes, shared by the LevelDB and IndexedDB readers. Every read
/// returns nil instead of trapping when the input is too short, so malformed files surface as
/// errors the callers choose how to handle.
nonisolated struct ByteReader {
    let bytes: ArraySlice<UInt8>
    private(set) var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    var isAtEnd: Bool { position >= bytes.endIndex }
    var remaining: Int { bytes.endIndex - position }

    mutating func readByte() -> UInt8? {
        guard position < bytes.endIndex else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    func peekByte() -> UInt8? {
        position < bytes.endIndex ? bytes[position] : nil
    }

    mutating func read(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, count <= remaining else { return nil }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, count <= remaining else { return false }
        position += count
        return true
    }

    mutating func readUInt32LE() -> UInt32? {
        guard let raw = read(4) else { return nil }
        var value: UInt32 = 0
        for byte in raw.reversed() { value = value << 8 | UInt32(byte) }
        return value
    }

    mutating func readUInt64LE() -> UInt64? {
        guard let raw = read(8) else { return nil }
        var value: UInt64 = 0
        for byte in raw.reversed() { value = value << 8 | UInt64(byte) }
        return value
    }

    mutating func readUInt32BE() -> UInt32? {
        guard let raw = read(4) else { return nil }
        var value: UInt32 = 0
        for byte in raw { value = value << 8 | UInt32(byte) }
        return value
    }

    mutating func readUInt64BE() -> UInt64? {
        guard let raw = read(8) else { return nil }
        var value: UInt64 = 0
        for byte in raw { value = value << 8 | UInt64(byte) }
        return value
    }

    mutating func readDoubleLE() -> Double? {
        readUInt64LE().map(Double.init(bitPattern:))
    }

    /// A little-endian base-128 varint of at most 10 bytes (64 bits).
    mutating func readVarint64() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        let start = position
        while let byte = readByte() {
            if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 70 { break }
        }
        position = start
        return nil
    }

    /// A varint of at most 5 bytes, as LevelDB's `GetVarint32`.
    mutating func readVarint32() -> UInt32? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        let start = position
        while let byte = readByte() {
            if shift < 32 { result |= UInt32(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 35 { break }
        }
        position = start
        return nil
    }
}
