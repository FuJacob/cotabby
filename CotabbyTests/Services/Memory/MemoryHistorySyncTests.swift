import CryptoKit
import Foundation
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
