import Foundation
import XCTest
@testable import Cotabby

/// Pins the readers under the Teams memory source, bottom up, with byte fixtures built here the way
/// Snappy, LevelDB, Chromium IndexedDB and V8 write them: Snappy blocks (literals, copies,
/// overlapping copies, corrupt input), LevelDB logs (batches, deletions, fragments across blocks, a
/// torn tail) and tables (prefix-compressed entries, compressed blocks, newer versions elsewhere),
/// V8 values (every supported tag, back-references, malformed input), and finally a whole Teams
/// cache read through `TeamsCacheReader`, including blob-stored and compressed values, the cursor
/// and its look-back.
final class TeamsIndexedDBTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("teams-indexeddb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Snappy

    func test_snappyDecodesLiteralsAndCopies() throws {
        // "abc" then a 1-byte-offset copy of 9 bytes from 3 back: an overlapping copy repeats "abc".
        XCTAssertEqual(try SnappyDecoder.decompress([12, 0x08, 97, 98, 99, 0x15, 3]), Array("abcabcabcabc".utf8))
        // A 2-byte-offset copy and a 4-byte-offset copy of "hello".
        let hello = Array("hello world ".utf8)
        XCTAssertEqual(
            try SnappyDecoder.decompress(Self.concat([22, UInt8(11 << 2)], hello, [0x12, 12, 0, 0x13, 17, 0, 0, 0])),
            Self.concat(hello, Array("hellohello".utf8))
        )
        // A literal longer than 60 bytes carries its length in the next byte.
        let long = [UInt8](repeating: 7, count: 100)
        XCTAssertEqual(try SnappyDecoder.decompress(Self.concat([100, 60 << 2, 99], long)), long)
        let longThenHello = Self.concat(long, hello)
        XCTAssertEqual(try SnappyDecoder.decompress(Self.snappyLiterals(longThenHello)), longThenHello)
        XCTAssertEqual(try SnappyDecoder.decompress([0]), [])
    }

    func test_snappyRejectsCorruptInput() {
        XCTAssertThrowsError(try SnappyDecoder.decompress([4, 0x08, 97, 98, 99, 0x05, 0])) { error in
            XCTAssertEqual(error as? SnappyDecoder.DecodeError, .invalidOffset, "offset 0")
        }
        XCTAssertThrowsError(try SnappyDecoder.decompress([8, 0x08, 97, 98, 99, 0x05, 9])) { error in
            XCTAssertEqual(error as? SnappyDecoder.DecodeError, .invalidOffset, "before the start of the output")
        }
        XCTAssertThrowsError(try SnappyDecoder.decompress([3, 0x08, 97])) { error in
            XCTAssertEqual(error as? SnappyDecoder.DecodeError, .truncated)
        }
        XCTAssertThrowsError(try SnappyDecoder.decompress([5, 0x08, 97, 98, 99])) { error in
            XCTAssertEqual(error as? SnappyDecoder.DecodeError, .lengthMismatch, "shorter than announced")
        }
        XCTAssertThrowsError(try SnappyDecoder.decompress([2, 0x08, 97, 98, 99])) { error in
            XCTAssertEqual(error as? SnappyDecoder.DecodeError, .lengthMismatch, "longer than announced")
        }
        XCTAssertThrowsError(try SnappyDecoder.decompress([0xFF, 0xFF, 0xFF, 0xFF, 0x0F])) { error in
            XCTAssertEqual(error as? SnappyDecoder.DecodeError, .tooLarge)
        }
    }

    // MARK: - LevelDB

    func test_logBatchesResolveToTheNewestVersionAndDropDeletions() throws {
        let folder = try makeFolder("log", files: [
            "000004.log": Self.logFile([
                Self.batch(sequence: 1, [(Array("a".utf8), Array("1".utf8)), (Array("b".utf8), Array("2".utf8))]),
                Self.batch(sequence: 3, [(Array("a".utf8), nil), (Array("c".utf8), Array("3".utf8)), (Array("b".utf8), Array("4".utf8))])
            ])
        ])
        let snapshot = try LevelDBReader(folder: folder).read()
        XCTAssertEqual(Self.strings(snapshot), ["b": "4", "c": "3"])
        XCTAssertEqual(snapshot.versionsRead, 5)
    }

    /// A damaged batch header with a sequence at the top of the range must not trap on the
    /// per-entry sequence (the reader promises a corrupt file throws or is skipped, never crashes).
    func test_aSequenceAtTheTopOfTheRangeDoesNotTrap() throws {
        let folder = try makeFolder("overflow", files: [
            "000005.log": Self.logFile([
                Self.batch(sequence: UInt64.max, [(Array("a".utf8), Array("1".utf8)), (Array("b".utf8), Array("2".utf8))])
            ])
        ])
        XCTAssertEqual(Set(Self.strings(try LevelDBReader(folder: folder).read()).keys), ["a", "b"])
    }

    func test_logRecordsFragmentedAcrossBlocksAreJoined() throws {
        let big = [UInt8]((0..<70_000).map { UInt8($0 % 251) })
        let folder = try makeFolder("fragments", files: [
            "000009.log": Self.logFile([
                Self.batch(sequence: 1, [(Array("small".utf8), [1])]),
                Self.batch(sequence: 2, [(Array("big".utf8), big)]),
                Self.batch(sequence: 3, [(Array("after".utf8), [2])])
            ])
        ])
        let entries = try LevelDBReader(folder: folder).read().entries
        XCTAssertEqual(entries[Array("big".utf8)].map(Array.init), big)
        XCTAssertEqual(entries[Array("after".utf8)].map(Array.init), [2])
        XCTAssertEqual(entries.count, 3)
    }

    func test_aTornLogTailIsIgnored() throws {
        var log = Self.logFile([Self.batch(sequence: 1, [(Array("kept".utf8), [1])])])
        // A FULL fragment announcing more bytes than were written: Teams is mid-write.
        log += Self.concat([0, 0, 0, 0, 200, 0, 1], Self.batch(sequence: 2, [(Array("torn".utf8), [2])]))
        let folder = try makeFolder("torn", files: ["000002.log": log])
        XCTAssertEqual(Self.strings(try LevelDBReader(folder: folder).read()).keys.sorted(), ["kept"])
    }

    func test_tablesAreReadAndNewerLogEntriesWin() throws {
        let tableEntries: [(key: String, sequence: UInt64, value: String?)] = [
            ("apple", 1, "red"), ("apricot", 2, "orange"), ("banana", 3, "yellow"),
            ("blueberry", 4, "blue"), ("cherry", 5, nil), ("date", 6, "brown")
        ]
        let table = Self.tableFile(
            tableEntries.map { (Array($0.key.utf8), $0.sequence, $0.value.map { Array($0.utf8) }) },
            entriesPerBlock: 4, restartInterval: 2, compressBlocks: [false, true]
        )
        let folder = try makeFolder("table", files: [
            "000005.ldb": table,
            "000007.log": Self.logFile([
                Self.batch(sequence: 10, [(Array("banana".utf8), Array("green".utf8)), (Array("date".utf8), nil)]),
                // An older write than the table's (a log not yet deleted after compaction) loses.
                Self.batch(sequence: 0, [(Array("apple".utf8), Array("stale".utf8))])
            ]),
            "MANIFEST-000001": [1, 2, 3],
            "LOG": Array("not data".utf8)
        ])
        XCTAssertEqual(
            Self.strings(try LevelDBReader(folder: folder).read()),
            ["apple": "red", "apricot": "orange", "banana": "green", "blueberry": "blue"]
        )
    }

    func test_damagedTablesThrowAndMissingFilesReadAsNil() throws {
        var table = Self.tableFile([(Array("k".utf8), 1, Array("v".utf8))], entriesPerBlock: 4, restartInterval: 16, compressBlocks: [])
        table[table.count - 1] ^= 0xFF
        let folder = try makeFolder("damaged", files: ["000003.ldb": table])
        XCTAssertThrowsError(try LevelDBReader(folder: folder).read()) { error in
            guard case LevelDBReader.ReadError.corrupt = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertNil(try LevelDBReader.readFile(folder.appendingPathComponent("000999.ldb")))
        XCTAssertThrowsError(try LevelDBReader(folder: folder.appendingPathComponent("nope")).read())
    }

    // MARK: - V8 values

    func test_v8DecodesPrimitivesStringsAndContainers() throws {
        let value = try V8ValueDeserializer.deserialize(Self.v8(.object([
            ("ascii", .string("plain")), ("latin1", .string("Grüße")), ("twoByte", .string("Ayşe 👋")),
            ("int", .int(-42)), ("double", .number(1.5)), ("yes", .bool(true)), ("nothing", .null),
            ("missing", .undefined), ("list", .array([.int(1), .string("two")]))
        ]))[...])
        let object = try XCTUnwrap(value.object)
        XCTAssertEqual(object.keys, ["ascii", "latin1", "twoByte", "int", "double", "yes", "nothing", "missing", "list"])
        XCTAssertEqual(object["latin1"], .string("Grüße"))
        XCTAssertEqual(object["twoByte"], .string("Ayşe 👋"))
        XCTAssertEqual(object["int"], .number(-42))
        XCTAssertEqual(object["list"], .array([.number(1), .string("two")]))
        let plain = object.plainDictionary
        XCTAssertEqual(plain["double"] as? Double, 1.5)
        XCTAssertTrue(plain["missing"] is NSNull)
    }

    func test_v8DecodesTheRestOfItsTags() throws {
        // Hand-assembled: padding, uint32, Date, BigInt, a back-reference to an object, a sparse
        // array, a dense array with a hole, a Map, a Set, wrapped primitives, an ArrayBuffer with a
        // view, a Blink blob-index host object and an integer property key.
        var bytes: [UInt8] = [0xFF, 0x0F, 0x00, UInt8(ascii: "o")]
        func key(_ name: String) -> [UInt8] { Self.concat([UInt8(ascii: "\"")], Self.varint(UInt64(name.utf8.count)), Array(name.utf8)) }
        bytes += Self.concat(key("u"), [UInt8(ascii: "U")], Self.varint(300))
        bytes += Self.concat(key("date"), [UInt8(ascii: "D")], Self.doubleLE(1_790_000_000_000))
        bytes += Self.concat(key("big"), [UInt8(ascii: "Z"), 0x10], [0x01, 0, 0, 0, 0, 0, 0, 0]) // +1 in one 8-byte digit
        bytes += Self.concat(key("inner"), [UInt8(ascii: "o")], key("x"), [UInt8(ascii: "T"), UInt8(ascii: "{"), 1])
        bytes += Self.concat(key("again"), [UInt8(ascii: "^"), 2]) // ids: 0 outer object, 1 date, 2 inner
        bytes += Self.concat(key("sparse"), [UInt8(ascii: "a"), 5, UInt8(ascii: "I"), 8, UInt8(ascii: "F"), UInt8(ascii: "@"), 1, 5])
        bytes += Self.concat(key("dense"), [UInt8(ascii: "A"), 2, UInt8(ascii: "-"), UInt8(ascii: "0"), UInt8(ascii: "$"), 0, 2])
        bytes += Self.concat(key("map"), [UInt8(ascii: ";")], key("k"), [UInt8(ascii: "I"), 2, UInt8(ascii: ":"), 2])
        bytes += Self.concat(key("set"), [UInt8(ascii: "'"), UInt8(ascii: "I"), 2, UInt8(ascii: "I"), 4, UInt8(ascii: ","), 2])
        bytes += Self.concat(key("wrapped"), [UInt8(ascii: "s")], key("text"))
        bytes += Self.concat(key("number"), [UInt8(ascii: "n")], Self.doubleLE(2.5))
        bytes += Self.concat(key("buffer"), [UInt8(ascii: "B"), 3, 1, 2, 3, UInt8(ascii: "V"), UInt8(ascii: "B"), 0, 3, 0])
        bytes += Self.concat(key("blob"), [UInt8(ascii: "\\"), UInt8(ascii: "i"), 0])
        bytes += [UInt8(ascii: "I"), 14, UInt8(ascii: "T")] // integer key 7
        bytes += [UInt8(ascii: "{"), 14]
        let object = try XCTUnwrap(try V8ValueDeserializer.deserialize(bytes[...]).object)
        XCTAssertEqual(object["u"], .number(300))
        XCTAssertEqual(object["date"], .date(1_790_000_000_000))
        XCTAssertEqual(object["big"], .number(1))
        XCTAssertEqual(object["again"], object["inner"])
        XCTAssertEqual(object["sparse"], .array([.undefined, .undefined, .undefined, .undefined, .bool(false)]))
        XCTAssertEqual(object["dense"], .array([.undefined, .null]))
        XCTAssertEqual(object["map"], .object(V8Object([("k", .number(1))])))
        XCTAssertEqual(object["set"], .array([.number(1), .number(2)]))
        XCTAssertEqual(object["wrapped"], .string("text"))
        XCTAssertEqual(object["number"], .number(2.5))
        XCTAssertEqual(object["buffer"], .opaque)
        XCTAssertEqual(object["blob"], .opaque)
        XCTAssertEqual(object["7"], .bool(true))
    }

    func test_v8RejectsMalformedValuesWithoutCrashing() {
        let cases: [[UInt8]] = [
            [],                                              // no header
            [0x0F, 0x0F],                                    // not a version tag
            [0xFF, 0x0F],                                    // header only
            [0xFF, 0x0F, UInt8(ascii: "\""), 10, 65],        // string shorter than its length
            [0xFF, 0x0F, UInt8(ascii: "o"), UInt8(ascii: "{"), 3], // wrong property count
            [0xFF, 0x0F, UInt8(ascii: "^"), 0],              // reference to nothing
            [0xFF, 0x0F, UInt8(ascii: "A"), 0xFF, 0xFF, 0xFF, 0xFF, 0x0F], // absurd array length
            [0xFF, 0x0F, 0x01],                              // unknown tag
            [0xFF, 0x0F, UInt8(ascii: "\\"), UInt8(ascii: "?")], // unknown Blink host object
            Self.concat([0xFF, 0x0F], [UInt8](repeating: UInt8(ascii: "A"), count: 1000).flatMap { [$0, 1] }) // too deep
        ]
        for bytes in cases {
            XCTAssertThrowsError(try V8ValueDeserializer.deserialize(bytes[...]), "\(bytes.prefix(8))")
        }
        // A cycle (an object containing itself) decodes, with the inner reference undefined.
        let cyclic = Self.concat(
            [0xFF, 0x0F, UInt8(ascii: "o"), UInt8(ascii: "\""), 4], Array("self".utf8), [UInt8(ascii: "^"), 0, UInt8(ascii: "{"), 1]
        )
        XCTAssertEqual(try V8ValueDeserializer.deserialize(cyclic[...]), .object(V8Object([("self", .undefined)])))
    }

    // MARK: - Teams cache, end to end

    private let me = "8:orgid:aaaaaaaa-0000-0000-0000-000000000001"
    private let avery = "8:orgid:bbbbbbbb-0000-0000-0000-000000000002"
    private let oneToOne = "19:aaaaaaaa-0000-0000-0000-000000000001_bbbbbbbb-0000-0000-0000-000000000002@unq.gbl.spaces"
    private let group = "19:ops@thread.v2"
    private let t0: Double = 1_790_000_000_000

    private func chatMessage(_ id: String, _ conversation: String, _ creator: String, _ name: String,
                             _ content: String, at milliseconds: Double) -> (String, JS) {
        (id, .object([
            ("id", .string(id)), ("conversationId", .string(conversation)), ("creator", .string(creator)),
            ("imDisplayName", .string(name)), ("content", .string(content)), ("messageType", .string("RichText/Html")),
            ("originalArrivalTime", .number(milliseconds)), ("deletionInfo", .undefined)
        ]))
    }

    /// A cache with the three Teams databases, values stored every way Chromium stores them: in the
    /// log and in a table, plain, with a v21 trailer, Snappy-compressed and in a blob file; plus a
    /// chain deleted after it was written and a record that cannot be decoded.
    private func makeTeamsCache() throws -> URL {
        let origin = "https_teams.microsoft.com_0"
        let conversations = (database: UInt64(1), name: "Teams:conversation-manager:tenant")
        let chains = (database: UInt64(2), name: "Teams:replychain-manager:tenant")
        let profiles = (database: UInt64(3), name: "Teams:profiles:tenant")

        let oneToOneRow = JS.object([
            ("id", .string(oneToOne)), ("members", .array([.object([("id", .string(me))]), .object([("id", .string(avery))])]))
        ])
        let groupRow = JS.object([
            ("id", .string(group)), ("threadProperties", .object([("topic", .string("Ops"))])),
            ("members", .array([.object([("id", .string(me))])]))
        ])
        let chainA = JS.object([("messageMap", .object([
            chatMessage("m1", oneToOne, avery, "Avery P.", "<p>Grüße aus Berlin</p>", at: t0 + 1_000),
            chatMessage("m2", oneToOne, me, "Sam Archer", "<div>Thanks</div>", at: t0 + 2_000)
        ]))])
        let chainB = JS.object([("messageMap", .object([
            chatMessage("m3", group, avery, "Avery P.", "Budget approved", at: t0 + 3_000)
        ]))])
        let chainC = JS.object([("messageMap", .object([
            chatMessage("m4", group, me, "Sam Archer", "See you", at: t0 + 4_000)
        ]))])
        let chainD = JS.object([("messageMap", .object([
            chatMessage("m5", group, avery, "Avery P.", "a chain Teams deleted", at: t0 + 5_000)
        ]))])

        // Blob 5 of database 2 holds chain C (blob files are named in hex under the database id).
        let blobContents = Self.concat([0xFF, 20], Self.v8(chainC))
        let blobFolder = directory.appendingPathComponent("\(origin).indexeddb.blob/2/00")
        try FileManager.default.createDirectory(at: blobFolder, withIntermediateDirectories: true)
        try Data(blobContents).write(to: blobFolder.appendingPathComponent("5"))

        let compressedEnvelope = Self.concat([0xFF, 20], Self.v8(chainB))
        let metadata: [([UInt8], [UInt8]?)] = [
            (Self.databaseNameKey(origin: "https://teams.microsoft.com", name: conversations.name), [1]),
            (Self.databaseNameKey(origin: "https://teams.microsoft.com", name: chains.name), [2]),
            (Self.databaseNameKey(origin: "https://teams.microsoft.com", name: profiles.name), [3]),
            (Self.storeNameKey(database: 1, store: 1), Self.utf16BE("conversations")),
            (Self.storeNameKey(database: 2, store: 1), Self.utf16BE("replychains")),
            (Self.storeNameKey(database: 2, store: 2), Self.utf16BE("replychains-2")),
            (Self.storeNameKey(database: 3, store: 1), Self.utf16BE("profiles"))
        ]
        let records: [([UInt8], [UInt8]?)] = [
            (Self.recordKey(database: 1, store: 1, key: oneToOne), Self.recordValue(oneToOneRow)),
            (Self.recordKey(database: 1, store: 1, key: group), Self.recordValue(groupRow, blinkVersion: 21)),
            (Self.recordKey(database: 2, store: 2, key: "c2"),
             Self.concat([1, 0xFF, 0x11, 0x02], Self.snappyLiterals(compressedEnvelope))),
            (Self.recordKey(database: 2, store: 1, key: "c3"),
             Self.concat([1, 0xFF, 0x11, 0x01], Self.varint(UInt64(blobContents.count)), [0])),
            (Self.concat(IndexedDBReader.makePrefix(databaseID: 2, objectStoreID: 1, indexID: 3), Self.idbStringKey("c3")),
             Self.concat([0, 5, 0], Self.varint(UInt64(blobContents.count)))),
            (Self.recordKey(database: 2, store: 1, key: "c9"), [1, 0x00, 0x01]),
            // A blob index beyond Int's range: skipped as corrupt, never a trap.
            (Self.recordKey(database: 2, store: 1, key: "c8"),
             Self.concat([1, 0xFF, 0x11, 0x01], Self.varint(5), Self.varint(UInt64.max))),
            (Self.recordKey(database: 3, store: 1, key: avery),
             Self.recordValue(.object([("mri", .string(avery)), ("displayName", .string(" Avery Stone "))])))
        ]
        // The table holds chain A and the chain D that the log then deletes.
        let tableRows: [([UInt8], UInt64, [UInt8]?)] = [
            (Self.recordKey(database: 2, store: 1, key: "c1"), 1, Self.recordValue(chainA)),
            (Self.recordKey(database: 2, store: 1, key: "c4"), 2, Self.recordValue(chainD))
        ].sorted { $0.0.lexicographicallyPrecedes($1.0) }
        let leveldb = try makeFolder("\(origin).indexeddb.leveldb", files: [
            "000010.ldb": Self.tableFile(tableRows, entriesPerBlock: 1, restartInterval: 16, compressBlocks: [true, false]),
            "000012.log": Self.logFile([
                Self.batch(sequence: 100, metadata),
                Self.batch(sequence: 200, records),
                Self.batch(sequence: 300, [(Self.recordKey(database: 2, store: 1, key: "c4"), nil)])
            ]),
            "CURRENT": Array("MANIFEST-000001\n".utf8)
        ])
        return leveldb
    }

    func test_teamsCacheReaderMapsEveryStorageFormOfTheCache() throws {
        let reader = TeamsCacheReader(indexedDBFolders: [try makeTeamsCache().path])
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 10)

        XCTAssertEqual(page.records.map(\.sourceMessageID).sorted(), ["\(oneToOne)/m1", "\(oneToOne)/m2", "\(group)/m3", "\(group)/m4"])
        let byID = Dictionary(uniqueKeysWithValues: page.records.map { ($0.sourceMessageID, $0) })
        let greeting = try XCTUnwrap(byID["\(oneToOne)/m1"])
        XCTAssertEqual(greeting.text, "Grüße aus Berlin", "a Latin-1 string decodes to its text")
        XCTAssertEqual(greeting.sender, "Avery Stone", "the profile name wins over the message's")
        XCTAssertEqual(greeting.conversationTitle, "Avery Stone")
        XCTAssertEqual(greeting.participants, [avery])
        XCTAssertEqual(greeting.timestamp.timeIntervalSince1970, (t0 + 1_000) / 1000)
        XCTAssertFalse(greeting.isFromMe)
        XCTAssertTrue(try XCTUnwrap(byID["\(oneToOne)/m2"]).isFromMe)
        let budget = try XCTUnwrap(byID["\(group)/m3"])
        XCTAssertEqual(budget.text, "Budget approved", "Snappy-wrapped value")
        XCTAssertEqual(budget.conversationTitle, "Ops")
        XCTAssertEqual(budget.participants, [avery, TeamsMessageMapper.groupMarker + group])
        XCTAssertEqual(byID["\(group)/m4"]?.text, "See you", "value stored in a blob file")
        XCTAssertNil(byID["\(group)/m5"], "a chain deleted in the log is gone")
        XCTAssertEqual(page.nextCursor, String(Int64(t0 + 4_000)))
        XCTAssertFalse(page.hasMore)

    }

    func test_teamsCursorLooksBackTwoDaysAndNeverMovesBack() throws {
        let reader = TeamsCacheReader(indexedDBFolders: [try makeTeamsCache().path])
        // Re-reading from a stored cursor (the "1790000000000.0" form parses too) finds the last two days again.
        let again = try reader.read(after: "\(Int64(t0 + 4_000)).0", since: nil, limit: 10)
        XCTAssertEqual(again.records.count, 4)
        XCTAssertNil(again.nextCursor, "nothing newer than the cursor")
        let later = try reader.read(after: String(Int64(t0 + 3 * 86_400_000)), since: nil, limit: 10)
        XCTAssertTrue(later.records.isEmpty)
        XCTAssertNil(later.nextCursor)
        // The retention window applies too.
        let recent = try reader.read(after: nil, since: Date(timeIntervalSince1970: (t0 + 2_500) / 1000), limit: 10)
        XCTAssertEqual(recent.records.map(\.text).sorted(), ["Budget approved", "See you"])
    }

    func test_teamsReadinessReportsAMissingCache() {
        let reader = TeamsCacheReader(webViewRoot: directory.appendingPathComponent("absent").path)
        XCTAssertEqual(reader.readiness(), .notFound("No Teams cache on this Mac. Open the new Teams app once."))
        XCTAssertThrowsError(try reader.read(after: nil, since: nil, limit: 10))
        let empty = TeamsCacheReader(webViewRoot: directory.path)
        XCTAssertEqual(empty.readiness(), .notFound("Teams has not cached any chats yet."))
    }

    // MARK: - Fixture builders

    private func makeFolder(_ name: String, files: [String: [UInt8]]) throws -> URL {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, bytes) in files { try Data(bytes).write(to: folder.appendingPathComponent(file)) }
        return folder
    }

    private static func strings(_ snapshot: LevelDBReader.Snapshot) -> [String: String] {
        Dictionary(uniqueKeysWithValues: snapshot.entries.map { (String(decoding: $0.key, as: UTF8.self), String(decoding: $0.value, as: UTF8.self)) })
    }

    /// Joins byte runs. Fixtures use this rather than chains of `+` on array literals, which older
    /// Swift compilers take seconds to type-check (or give up on) in a test build.
    static func concat(_ parts: [UInt8]...) -> [UInt8] {
        var bytes: [UInt8] = []
        for part in parts { bytes.append(contentsOf: part) }
        return bytes
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<(T.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    static func doubleLE(_ value: Double) -> [UInt8] { littleEndian(value.bitPattern) }

    /// Snappy with literals only (valid, and enough to exercise the compressed paths).
    static func snappyLiterals(_ bytes: [UInt8]) -> [UInt8] {
        var output = varint(UInt64(bytes.count))
        var index = 0
        while index < bytes.count {
            let chunk = min(65_536, bytes.count - index)
            output += concat([61 << 2], littleEndian(UInt16(chunk - 1)), Array(bytes[index..<(index + chunk)]))
            index += chunk
        }
        return output
    }

    /// A write batch: sequence, count, then puts (with a value) and deletions (nil).
    static func batch(sequence: UInt64, _ entries: [([UInt8], [UInt8]?)]) -> [UInt8] {
        var bytes = concat(littleEndian(sequence), littleEndian(UInt32(entries.count)))
        for (key, value) in entries {
            if let value {
                bytes += concat([1], varint(UInt64(key.count)), key, varint(UInt64(value.count)), value)
            } else {
                bytes += concat([0], varint(UInt64(key.count)), key)
            }
        }
        return bytes
    }

    /// A log file of these batches, split into FULL / FIRST / MIDDLE / LAST fragments across 32 KB
    /// blocks with zero padding where a header no longer fits, as LevelDB writes it.
    static func logFile(_ batches: [[UInt8]]) -> [UInt8] {
        var output: [UInt8] = []
        for batch in batches {
            var remaining = batch[...]
            var first = true
            while !remaining.isEmpty {
                let left = LevelDBReader.logBlockSize - output.count % LevelDBReader.logBlockSize
                if left < 7 {
                    output += [UInt8](repeating: 0, count: left)
                    continue
                }
                let length = min(left - 7, remaining.count)
                let last = length == remaining.count
                let type: UInt8 = first ? (last ? 1 : 2) : (last ? 4 : 3)
                output += concat([0, 0, 0, 0], littleEndian(UInt16(length)), [type], Array(remaining.prefix(length)))
                remaining = remaining.dropFirst(length)
                first = false
            }
        }
        return output
    }

    /// A table of internal keys (user key + sequence/type), `entriesPerBlock` per data block, with
    /// shared-prefix compression restarted every `restartInterval` entries; data block `i` is
    /// Snappy-compressed when `compressBlocks[i]` is true.
    static func tableFile(_ entries: [([UInt8], UInt64, [UInt8]?)], entriesPerBlock: Int, restartInterval: Int,
                          compressBlocks: [Bool]) -> [UInt8] {
        func block(_ items: [([UInt8], [UInt8])]) -> [UInt8] {
            var bytes: [UInt8] = []
            var restarts: [UInt32] = []
            var previous: [UInt8] = []
            for (index, (key, value)) in items.enumerated() {
                var shared = 0
                if index % restartInterval == 0 {
                    restarts.append(UInt32(bytes.count))
                } else {
                    while shared < min(previous.count, key.count), previous[shared] == key[shared] { shared += 1 }
                }
                bytes += concat(varint(UInt64(shared)), varint(UInt64(key.count - shared)), varint(UInt64(value.count)))
                bytes += concat(Array(key[shared...]), value)
                previous = key
            }
            if restarts.isEmpty { restarts = [0] }
            return concat(bytes, restarts.flatMap { littleEndian($0) }, littleEndian(UInt32(restarts.count)))
        }
        var file: [UInt8] = []
        var index: [([UInt8], [UInt8])] = []
        func append(_ contents: [UInt8], compress: Bool) -> (UInt64, UInt64) {
            let stored = compress ? snappyLiterals(contents) : contents
            let handle = (UInt64(file.count), UInt64(stored.count))
            file += concat(stored, [compress ? 1 : 0, 0, 0, 0, 0])
            return handle
        }
        let internalEntries: [([UInt8], [UInt8])] = entries.map { key, sequence, value in
            let tag: UInt64 = value == nil ? 0 : 1
            return (concat(key, littleEndian(sequence << 8 | tag)), value ?? [])
        }
        var blockNumber = 0
        for start in stride(from: 0, to: internalEntries.count, by: entriesPerBlock) {
            let items = Array(internalEntries[start..<min(start + entriesPerBlock, internalEntries.count)])
            let compress = blockNumber < compressBlocks.count && compressBlocks[blockNumber]
            let handle = append(block(items), compress: compress)
            index.append((items.last!.0, concat(varint(handle.0), varint(handle.1))))
            blockNumber += 1
        }
        let metaIndex = append(block([]), compress: false)
        let indexHandle = append(block(index), compress: false)
        var footer = concat(varint(metaIndex.0), varint(metaIndex.1), varint(indexHandle.0), varint(indexHandle.1))
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        return concat(file, footer, littleEndian(LevelDBReader.tableMagic))
    }

    // MARK: IndexedDB and V8

    indirect enum JS {
        case string(String)
        case number(Double)
        case int(Int32)
        case bool(Bool)
        case null
        case undefined
        case object([(String, JS)])
        case array([JS])
    }

    /// V8's serialization of `value`, version 15, choosing one-byte strings for Latin-1 text as V8 does.
    static func v8(_ value: JS) -> [UInt8] {
        func string(_ text: String) -> [UInt8] {
            let scalars = Array(text.unicodeScalars)
            if scalars.allSatisfy({ $0.value <= 0xFF }) {
                return concat([UInt8(ascii: "\"")], varint(UInt64(scalars.count)), scalars.map { UInt8($0.value) })
            }
            let units = Array(text.utf16)
            return concat([UInt8(ascii: "c")], varint(UInt64(units.count * 2)), units.flatMap { littleEndian($0) })
        }
        func encode(_ value: JS) -> [UInt8] {
            switch value {
            case .string(let text): return string(text)
            case .number(let number): return concat([UInt8(ascii: "N")], doubleLE(number))
            case .int(let int):
                let zigzag = UInt32(bitPattern: (int << 1) ^ (int >> 31))
                return concat([UInt8(ascii: "I")], varint(UInt64(zigzag)))
            case .bool(let flag): return [UInt8(ascii: flag ? "T" : "F")]
            case .null: return [UInt8(ascii: "0")]
            case .undefined: return [UInt8(ascii: "_")]
            case .object(let pairs):
                let properties: [UInt8] = pairs.flatMap { concat(string($0.0), encode($0.1)) }
                return concat([UInt8(ascii: "o")], properties, [UInt8(ascii: "{")], varint(UInt64(pairs.count)))
            case .array(let items):
                let elements: [UInt8] = items.flatMap(encode)
                return concat([UInt8(ascii: "A")], varint(UInt64(items.count)), elements, [UInt8(ascii: "$"), 0], varint(UInt64(items.count)))
            }
        }
        return concat([0xFF, 0x0F], encode(value))
    }

    static func utf16BE(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    static func databaseNameKey(origin: String, name: String) -> [UInt8] {
        concat([0, 0, 0, 0, 201], varint(UInt64(origin.utf16.count)), utf16BE(origin), varint(UInt64(name.utf16.count)), utf16BE(name))
    }

    static func storeNameKey(database: UInt64, store: UInt64) -> [UInt8] {
        concat(IndexedDBReader.makePrefix(databaseID: database, objectStoreID: 0, indexID: 0), [50], varint(store), [0])
    }

    /// An IndexedDB string key: type 1, length in UTF-16 units, big-endian UTF-16.
    static func idbStringKey(_ key: String) -> [UInt8] {
        concat([1], varint(UInt64(key.utf16.count)), utf16BE(key))
    }

    static func recordKey(database: UInt64, store: UInt64, key: String) -> [UInt8] {
        concat(IndexedDBReader.makePrefix(databaseID: database, objectStoreID: store, indexID: 1), idbStringKey(key))
    }

    /// A record value: version varint, Blink envelope (with the v21 trailer when asked), V8 bytes.
    static func recordValue(_ value: JS, blinkVersion: UInt8 = 20) -> [UInt8] {
        let trailer: [UInt8] = blinkVersion >= 21 ? concat([0xFE], [UInt8](repeating: 0, count: 12)) : []
        return concat([1, 0xFF, blinkVersion], trailer, v8(value))
    }

    func test_aHugelySparseArrayIsNotExpandedToItsClaimedLength() throws {
        // [0xFF 0x0F] version, 'a' sparse array of length 4,000,000,000 with one element at index
        // 2,000,000,000 (int key, zigzag varint), then '@' with 1 property and the length again.
        let length = Self.varint(4_000_000_000)
        let bytes = Self.concat(
            [0xFF, 0x0F, UInt8(ascii: "a")], length,
            [UInt8(ascii: "I")], Self.varint(4_000_000_000), [UInt8(ascii: "T")],
            [UInt8(ascii: "@"), 1], length
        )
        let started = Date()
        let value = try V8ValueDeserializer.deserialize(bytes[...])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        guard case .array(let elements) = value else { return XCTFail("expected an array") }
        XCTAssertEqual(elements, [.bool(true)])
    }
}
