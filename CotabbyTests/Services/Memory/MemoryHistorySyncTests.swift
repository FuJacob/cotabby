import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Cotabby

/// Pins how a memory sync stops: a cancelled sync stores nothing it read after the cancel, keeps
/// the cursor of the last page it stored, and `cancelSync` returns only once the sync has ended, so
/// Forget and Delete All can delete without a page coming back.
@MainActor
final class MemoryHistorySyncTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine() throws -> MemoryEngine {
        let engine = try MemoryEngine(
            paths: MemoryEngine.Paths(dataDirectory: directory),
            rootKey: SymmetricKey(data: Data(0..<32)),
            modelURL: directory.appendingPathComponent("none.gguf"),
            conditions: {
                EmbeddingSchedulePolicy.Conditions(isOnACPower: true, isLowPowerMode: false, thermalState: .nominal,
                                                   userIdleSeconds: 60, isGenerating: false, pendingPassages: 0)
            }
        )
        try engine.updateConfiguration { $0.sources[PagedReader.source] = MemorySourceSettings(enabled: true) }
        return engine
    }

    func test_aCancelledSyncStopsAtItsLastStoredPage() async throws {
        let engine = try makeEngine()
        let reader = PagedReader()
        let sync = MemoryHistorySync(readers: [reader], engine: { engine }, isOnACPower: { true })

        let running = Task { await sync.sync(PagedReader.source) }
        try await waitUntil { reader.isWaitingOnSecondPage }
        XCTAssertEqual(sync.syncing, [PagedReader.source])

        let cancelling = Task { await sync.cancelSync(PagedReader.source) }
        try await Task.sleep(nanoseconds: 50_000_000)  // `cancelSync` marks the run before it waits.
        reader.releaseSecondPage()
        await cancelling.value
        await running.value

        XCTAssertEqual(engine.cursor(source: PagedReader.source), "1", "the page read during the cancel is dropped with its cursor")
        XCTAssertTrue(sync.syncing.isEmpty)
        XCTAssertEqual(reader.pagesRead, 2, "nothing is read after the cancel")
    }

    func test_aStoppedEngineStoresNothing() throws {
        let engine = try makeEngine()
        engine.markStopped()
        let record = MemoryIngestRecord(sourceMessageID: "m", conversationID: "c", conversationTitle: "C", sender: "Ayşe",
                                        isFromMe: false, timestamp: Date(), text: "the invoice is paid",
                                        participants: [], subject: nil)
        XCTAssertEqual(try engine.ingest(source: PagedReader.source, records: [record], cursor: "9").stored, 0)
        XCTAssertNil(engine.cursor(source: PagedReader.source))
    }

    /// The whole path of a re-linked WhatsApp: memory read the old store, WhatsApp was logged out
    /// (its container stays, the chat store goes), then linked again with a new store whose rows
    /// count from 1. Memory says it is not linked meanwhile, and stores the new store's messages.
    func test_aRelinkedWhatsAppIsReadAgainAfterBeingReportedNotLinked() async throws {
        let engine = try makeEngine()
        try engine.updateConfiguration { $0.sources[WhatsAppFixture.source] = MemorySourceSettings(enabled: true) }
        let path = directory.appendingPathComponent("ChatStorage.sqlite").path
        let sync = MemoryHistorySync(readers: [WhatsAppHistoryReader(databasePath: path)],
                                     engine: { engine }, isOnACPower: { true })

        try WhatsAppFixture.write(path, storeID: "OLD", messages: (1...40).map { ("old message \($0) about the invoice", $0) })
        await sync.sync(WhatsAppFixture.source)
        XCTAssertEqual(engine.cursor(source: WhatsAppFixture.source), "OLD:40")

        try FileManager.default.removeItem(atPath: path)
        await sync.sync(WhatsAppFixture.source)
        guard case .notFound(let message) = sync.readiness[WhatsAppFixture.source] else {
            return XCTFail("expected not found, got \(String(describing: sync.readiness[WhatsAppFixture.source]))")
        }
        XCTAssertTrue(message.contains("not linked"), message)

        try WhatsAppFixture.write(path, storeID: "NEW", messages: [("linked again, the budget is fixed", 1)])
        await sync.sync(WhatsAppFixture.source)
        XCTAssertEqual(sync.readiness[WhatsAppFixture.source], .ready)
        XCTAssertEqual(engine.cursor(source: WhatsAppFixture.source), "NEW:1")
        let stats = engine.sources().first { $0.id == WhatsAppFixture.source }?.stats
        XCTAssertEqual(stats?.messages, 41, "the new store's message is stored next to what memory kept")
    }

    /// Linking WhatsApp while the Memory pane waits on it: the next readiness check (the pane
    /// appearing, Cotabby becoming active) finds the store and reads it then, not a round later.
    func test_aSourceThatBecomesReadableIsSyncedWhenReadinessIsRechecked() async throws {
        let engine = try makeEngine()
        try engine.updateConfiguration { $0.sources[WhatsAppFixture.source] = MemorySourceSettings(enabled: true) }
        let path = directory.appendingPathComponent("ChatStorage.sqlite").path
        let sync = MemoryHistorySync(readers: [WhatsAppHistoryReader(databasePath: path)],
                                     engine: { engine }, isOnACPower: { true })
        await sync.sync(WhatsAppFixture.source)
        XCTAssertEqual(sync.readiness[WhatsAppFixture.source]?.isReady, false)

        try WhatsAppFixture.write(path, storeID: "NEW", messages: [("linked again, the budget is fixed", 1)])
        sync.refreshReadiness()
        try await waitUntil { engine.cursor(source: WhatsAppFixture.source) == "NEW:1" }
    }

    func test_aSourceThatBecomesReadableWaitsForACPower() async throws {
        let engine = try makeEngine()
        try engine.updateConfiguration { $0.sources[WhatsAppFixture.source] = MemorySourceSettings(enabled: true) }
        let path = directory.appendingPathComponent("ChatStorage.sqlite").path
        let sync = MemoryHistorySync(readers: [WhatsAppHistoryReader(databasePath: path)],
                                     engine: { engine }, isOnACPower: { false })
        await sync.sync(WhatsAppFixture.source)

        try WhatsAppFixture.write(path, storeID: "NEW", messages: [("linked again, the budget is fixed", 1)])
        sync.refreshReadiness()
        try await waitUntil { sync.readiness[WhatsAppFixture.source] == .ready }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(engine.cursor(source: WhatsAppFixture.source), "on battery it waits for the next round on AC")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}

/// A source with three one-message pages whose second page waits until the test releases it.
private final class PagedReader: MemoryHistoryReading, @unchecked Sendable {
    static let source = "paged"
    let sourceID = PagedReader.source

    private let lock = NSLock()
    private let secondPage = DispatchSemaphore(value: 0)
    private var reads = 0
    private var waiting = false

    var pagesRead: Int { locked { reads } }
    var isWaitingOnSecondPage: Bool { locked { waiting } }

    func releaseSecondPage() {
        secondPage.signal()
    }

    func readiness() -> MemorySourceReadiness { .ready }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let page = locked { () -> Int in
            reads += 1
            return reads
        }
        if page == 2 {
            locked { waiting = true }
            secondPage.wait()
        }
        let record = MemoryIngestRecord(
            sourceMessageID: "m\(page)", conversationID: "c", conversationTitle: "Chat", sender: "Ayşe",
            isFromMe: false, timestamp: Date(), text: "message number \(page) about the invoice",
            participants: ["ayse"], subject: nil
        )
        return MemoryReadPage(records: [record], nextCursor: String(page), hasMore: page < 3)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A minimal WhatsApp chat store: the tables and columns `WhatsAppHistoryReader` reads, one 1:1
/// chat, and messages dated just now (so retention keeps them), keyed by stanza id per store.
private enum WhatsAppFixture {
    static let source = "whatsapp"

    static func write(_ path: String, storeID: String, messages: [(text: String, row: Int)]) throws {
        let now = Date().timeIntervalSince1970 - WhatsAppHistoryReader.appleEpochOffset
        let rows = messages.map { message in
            "(\(message.row), '\(message.text)', 0, \(now), 1, NULL, '\(storeID)-\(message.row)', NULL, 0)"
        }
        var sql = """
        CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB);
        INSERT INTO Z_METADATA VALUES (1, '\(storeID)', NULL);
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR, ZSESSIONTYPE INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEMBERJID VARCHAR, ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTEXT VARCHAR, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP,
            ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER, ZSTANZAID VARCHAR, ZPUSHNAME VARCHAR, ZGROUPEVENTTYPE INTEGER);
        INSERT INTO ZWACHATSESSION VALUES (1, '15550100001@s.whatsapp.net', 'Ayşe', 0);
        """
        if !rows.isEmpty { sql += "INSERT INTO ZWAMESSAGE VALUES \(rows.joined(separator: ", "));" }
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture", code: 2) }
    }
}
