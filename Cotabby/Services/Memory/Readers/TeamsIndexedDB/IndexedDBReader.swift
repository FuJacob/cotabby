import Foundation

/// File overview:
/// Reads the databases, object stores and values of one Chromium IndexedDB origin
/// (`<origin>.indexeddb.leveldb` plus its `.blob` folder), read-only, for the Teams cache reader.
///
/// Why its own type: Chromium lays IndexedDB out over LevelDB with its own key coding
/// (https://chromium.googlesource.com/chromium/src/+/main/content/browser/indexed_db/docs/leveldb_coding_scheme.md),
/// independent of what the web app stores. This type turns `LevelDBReader`'s raw snapshot into
/// "database name -> object store name -> values", and leaves the meaning of those values to
/// `TeamsCacheReader`.
///
/// The key coding used here:
/// - Every key starts with a prefix: one byte giving the byte lengths of the database id, object
///   store id and index id (`xxxyyyzz`: lengths minus one), then those three little-endian ids.
/// - Global metadata has ids 0/0/0. Its `DatabaseNameKey` (type byte 201) is followed by the origin
///   and the database name, each a varint count of UTF-16 code units then big-endian UTF-16; the
///   value is the database id ("truncated int": little-endian bytes, as many as needed).
/// - Database metadata has the database id and 0/0. Type 50 is object store metadata: varint store
///   id, then a type byte; type 0's value is the store's name (big-endian UTF-16, no length).
/// - A store's records have index id 1; the rest of the key is the record's IndexedDB key. The value
///   is a varint version, then Blink's envelope (`0xFF`, varint Blink version) around V8's bytes.
///   Blink version 17 is a wrapper: the next byte 1 means the value was too big and lives in a blob
///   file (varint size, varint blob index), 2 means it is Snappy-compressed. Versions 21 and up
///   carry a 13-byte trailer (`0xFE`, u64 offset, u32 size) before V8's bytes.
/// - Index id 3 holds a record's external objects (blobs): for each, a type byte, varint blob
///   number, MIME type and size (and a file name and date for files). Blob `n` of database `d` is
///   the file `<origin>.indexeddb.blob/<d hex>/<(n >> 8) as 2 hex digits>/<n hex>`.
///
/// Ported from CCL Forensics' `ccl_chromium_indexeddb` (MIT, see THIRD_PARTY_LICENSES.md),
/// `read_record_precursor` in particular. Unlike the original it reads only the newest live
/// version of each record (the original also yielded superseded and deleted versions) and skips a
/// record it cannot decode instead of failing the whole read.
nonisolated struct IndexedDBReader {
    struct Database: Equatable {
        let id: UInt64
        let origin: String
        let name: String
        /// Object store names by store id.
        let objectStores: [UInt64: String]
    }

    struct Record {
        /// The record's encoded IndexedDB key (after the prefix).
        let key: ArraySlice<UInt8>
        let value: V8Value
    }

    let databases: [Database]
    /// Records that were present but could not be decoded (diagnostics; the read goes on).
    private(set) var undecodableRecords = 0
    private let snapshot: LevelDBReader.Snapshot
    private let blobFolder: URL?

    /// Reads the databases `wanted` accepts (by name), in two passes over the LevelDB files: the
    /// first keeps only metadata (which databases and stores exist), the second only the records
    /// and blob references of the wanted databases. Teams' origin holds about a hundred databases
    /// and memory needs three, so this keeps hundreds of megabytes of other data from ever being
    /// held, for the price of decompressing the files twice.
    init(levelDBFolder: URL, blobFolder: URL?, wanted: (String) -> Bool = { _ in true }) throws {
        let reader = LevelDBReader(folder: levelDBFolder)
        let metadata = try reader.read(keeping: { key in
            guard let prefix = Self.parsePrefix(key) else { return false }
            return prefix.objectStoreID == 0 && prefix.indexID == 0
        })
        let databases = Self.readDatabases(metadata.entries).filter { wanted($0.name) }
        let wantedIDs = Set(databases.map(\.id))
        var records = LevelDBReader.Snapshot(entries: [:], versionsRead: 0)
        if !wantedIDs.isEmpty {
            records = try reader.read(keeping: { key in
                guard let prefix = Self.parsePrefix(key) else { return false }
                return wantedIDs.contains(prefix.databaseID) && prefix.objectStoreID != 0
                    && (prefix.indexID == 1 || prefix.indexID == 3)
            })
        }
        self.init(snapshot: records, blobFolder: blobFolder, databases: databases)
    }

    /// Reads from a snapshot that holds everything (metadata included), as a single pass would.
    init(snapshot: LevelDBReader.Snapshot, blobFolder: URL?) {
        self.init(snapshot: snapshot, blobFolder: blobFolder, databases: Self.readDatabases(snapshot.entries))
    }

    private init(snapshot: LevelDBReader.Snapshot, blobFolder: URL?, databases: [Database]) {
        self.snapshot = snapshot
        self.blobFolder = blobFolder
        self.databases = databases
    }

    // MARK: - Key prefixes

    struct KeyPrefix: Equatable {
        let databaseID: UInt64
        let objectStoreID: UInt64
        let indexID: UInt64
        let length: Int
    }

    static func parsePrefix(_ key: ArraySlice<UInt8>) -> KeyPrefix? {
        guard let first = key.first else { return nil }
        let databaseLength = Int(first >> 5 & 0x07) + 1
        let storeLength = Int(first >> 2 & 0x07) + 1
        let indexLength = Int(first & 0x03) + 1
        let total = 1 + databaseLength + storeLength + indexLength
        guard key.count >= total else { return nil }
        func littleEndian(_ start: Int, _ count: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in (0..<count).reversed() {
                value = value << 8 | UInt64(key[key.startIndex + start + index])
            }
            return value
        }
        return KeyPrefix(
            databaseID: littleEndian(1, databaseLength),
            objectStoreID: littleEndian(1 + databaseLength, storeLength),
            indexID: littleEndian(1 + databaseLength + storeLength, indexLength),
            length: total
        )
    }

    static func makePrefix(databaseID: UInt64, objectStoreID: UInt64, indexID: UInt64) -> [UInt8] {
        func littleEndianBytes(_ value: UInt64) -> [UInt8] {
            var bytes: [UInt8] = []
            var remaining = value
            repeat {
                bytes.append(UInt8(remaining & 0xFF))
                remaining >>= 8
            } while remaining > 0
            return bytes
        }
        let database = littleEndianBytes(databaseID)
        let store = littleEndianBytes(objectStoreID)
        let index = littleEndianBytes(indexID)
        // Typed steps: as one expression this type-checks very slowly on older compilers.
        let databaseBits: Int = (database.count - 1) << 5
        let storeBits: Int = (store.count - 1) << 2
        let indexBits: Int = index.count - 1
        let first = UInt8(databaseBits | storeBits | indexBits)
        var prefix: [UInt8] = [first]
        prefix.append(contentsOf: database)
        prefix.append(contentsOf: store)
        prefix.append(contentsOf: index)
        return prefix
    }

    /// Chromium's "truncated int": little-endian bytes without padding.
    static func truncatedInt(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var value: UInt64 = 0
        for byte in bytes.reversed() { value = value << 8 | UInt64(byte) }
        return value
    }

    /// Big-endian UTF-16 of `units` code units.
    static func utf16BigEndian(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let high = UInt16(bytes[index]) << 8
            units.append(high | UInt16(bytes[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func lengthPrefixedUTF16(_ reader: inout ByteReader) -> String? {
        guard let units = reader.readVarint64(), units <= UInt64(reader.remaining / 2),
              let raw = reader.read(Int(units) * 2) else { return nil }
        return utf16BigEndian(raw)
    }

    // MARK: - Metadata

    private static func readDatabases(_ entries: [[UInt8]: ArraySlice<UInt8>]) -> [Database] {
        var identities: [Database] = []
        var storeNames: [UInt64: [UInt64: String]] = [:]
        for (key, value) in entries {
            guard let prefix = parsePrefix(key[...]), prefix.objectStoreID == 0, prefix.indexID == 0,
                  key.count > prefix.length else { continue }
            let typeByte = key[prefix.length]
            if prefix.databaseID == 0, typeByte == 201 {
                var reader = ByteReader(key[(prefix.length + 1)...])
                guard let origin = lengthPrefixedUTF16(&reader), let name = lengthPrefixedUTF16(&reader),
                      let id = truncatedInt(value) else { continue }
                identities.append(Database(id: id, origin: origin, name: name, objectStores: [:]))
            } else if prefix.databaseID != 0, typeByte == 50 {
                var reader = ByteReader(key[(prefix.length + 1)...])
                guard let storeID = reader.readVarint64(), reader.readByte() == 0,
                      let name = utf16BigEndian(value) else { continue }
                storeNames[prefix.databaseID, default: [:]][storeID] = name
            }
        }
        return identities
            .sorted { $0.id < $1.id }
            .map { Database(id: $0.id, origin: $0.origin, name: $0.name, objectStores: storeNames[$0.id] ?? [:]) }
    }

    // MARK: - Records

    /// Calls `body` with the decoded value of every live record of the named stores of `database`,
    /// store by store in the order given, each store's records in key order (bytewise). One value
    /// is decoded at a time, so a caller that keeps only a few fields of each never holds a whole
    /// store's decoded tree. A record whose value cannot be decoded (a missing blob file, an
    /// unsupported host object) is counted in `undecodableRecords` and skipped.
    mutating func forEachValue(in database: Database, stores: [String],
                               _ body: (V8Value) throws -> Void) rethrows {
        for storeName in stores {
            guard let storeID = database.objectStores.first(where: { $0.value == storeName })?.key else { continue }
            let prefix = Self.makePrefix(databaseID: database.id, objectStoreID: storeID, indexID: 1)
            let keys = snapshot.entries.keys
                .filter { $0.count > prefix.count && $0.starts(with: prefix) }
                .sorted { $0.lexicographicallyPrecedes($1) }
            for key in keys {
                guard let raw = snapshot.entries[key], !raw.isEmpty else { continue }
                let value: V8Value?
                do {
                    value = try decodeValue(raw, databaseID: database.id, storeID: storeID,
                                            recordKey: key[prefix.count...])
                } catch {
                    undecodableRecords += 1
                    continue
                }
                if let value { try body(value) }
            }
        }
    }

    enum ValueError: Error {
        case notBlinkValue
        case unexpectedWrapper
        case missingBlob
        case badTrailer
    }

    /// Where a record lives: its database, object store and key. Its external objects (blobs) are
    /// filed under the same three.
    private struct RecordLocation {
        let databaseID: UInt64
        let storeID: UInt64
        let recordKey: ArraySlice<UInt8>
    }

    /// A record value: varint version, then the Blink envelope (see the file overview).
    func decodeValue(_ raw: ArraySlice<UInt8>, databaseID: UInt64, storeID: UInt64,
                     recordKey: ArraySlice<UInt8>) throws -> V8Value? {
        var reader = ByteReader(raw)
        guard reader.readVarint64() != nil else { throw ValueError.notBlinkValue }
        let location = RecordLocation(databaseID: databaseID, storeID: storeID, recordKey: recordKey)
        return try decodeEnvelope(raw[reader.position...], location: location, depth: 0)
    }

    private func decodeEnvelope(_ bytes: ArraySlice<UInt8>, location: RecordLocation, depth: Int) throws -> V8Value? {
        // A wrapper can only point at a blob or compressed bytes, which are plain values; more than
        // one level of nesting is corrupt.
        guard depth < 3 else { throw ValueError.unexpectedWrapper }
        var reader = ByteReader(bytes)
        guard reader.readByte() == 0xFF, let blinkVersion = reader.readVarint64() else { throw ValueError.notBlinkValue }

        if blinkVersion == 0x11 {
            // kRequiresProcessingSSVPseudoVersion: the value was wrapped by idb_value_wrapping.cc.
            switch reader.readByte() {
            case 0x01: // kReplaceWithBlob
                // `Int(exactly:)`: a corrupt index beyond Int's range throws instead of trapping.
                guard reader.readVarint64() != nil, let rawIndex = reader.readVarint64(),
                      let blobIndex = Int(exactly: rawIndex) else { throw ValueError.notBlinkValue }
                guard let contents = try blobContents(location, index: blobIndex) else {
                    // The original returns nothing for a record whose blob is not described.
                    return nil
                }
                return try decodeEnvelope(contents[...], location: location, depth: depth + 1)
            case 0x02: // kCompressedWithSnappy
                let decompressed = try SnappyDecoder.decompress(bytes[reader.position...])
                return try decodeEnvelope(decompressed[...], location: location, depth: depth + 1)
            default:
                throw ValueError.unexpectedWrapper
            }
        }
        if blinkVersion >= 21 {
            // The trailer (offset/size of a "requires interfaces" list) is not needed to decode.
            guard reader.readByte() == 0xFE, reader.skip(12) else { throw ValueError.badTrailer }
        }
        return try V8ValueDeserializer.deserialize(bytes[reader.position...])
    }

    /// The bytes of the `index`-th external object of a record, or nil when the record has no such
    /// object. Throws when it is described but its file is gone.
    private func blobContents(_ location: RecordLocation, index: Int) throws -> [UInt8]? {
        let blobKey = Self.makePrefix(databaseID: location.databaseID, objectStoreID: location.storeID, indexID: 3)
            + location.recordKey
        guard let entry = snapshot.entries[blobKey],
              let blobNumber = Self.blobNumbers(entry).dropFirst(index).first else { return nil }
        guard let blobFolder else { throw ValueError.missingBlob }
        let url = blobFolder
            .appendingPathComponent(String(location.databaseID, radix: 16))
            .appendingPathComponent(String(format: "%02x", blobNumber >> 8))
            .appendingPathComponent(String(blobNumber, radix: 16))
        guard let contents = try LevelDBReader.readFile(url) else { throw ValueError.missingBlob }
        return contents
    }

    /// The blob numbers of a record's external objects, in order. Stops at an object type it
    /// cannot size (file system handles), which never precede blobs in practice.
    static func blobNumbers(_ value: ArraySlice<UInt8>) -> [UInt64] {
        var reader = ByteReader(value)
        var numbers: [UInt64] = []
        while !reader.isAtEnd {
            guard let type = reader.readByte(), type <= 1,
                  let number = reader.readVarint64(),
                  let mimeUnits = reader.readVarint64(), reader.skip(Int(min(mimeUnits, UInt64(Int32.max))) * 2),
                  reader.readVarint64() != nil else { break }
            if type == 1 { // a File: name and last-modified time follow
                guard let nameUnits = reader.readVarint64(), reader.skip(Int(min(nameUnits, UInt64(Int32.max))) * 2),
                      reader.readVarint64() != nil else { break }
            }
            numbers.append(number)
        }
        return numbers
    }
}
