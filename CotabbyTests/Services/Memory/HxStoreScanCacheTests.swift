import Foundation
import XCTest
@testable import Cotabby

/// Pins the incremental scan of New Outlook's store: a scan that reuses the previous scan's
/// segments returns exactly what a full scan of the changed file returns, whatever changed
/// (records added at the end or in a gap, rewritten in place, cut off, completed later, the file
/// shortened), and a second scan of an unchanged file decodes nothing.
final class HxStoreScanCacheTests: XCTestCase {
    private typealias Fixture = OutlookHxStoreTests
    private let sent = Date(timeIntervalSince1970: 1_790_000_000)
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hx-scan-\(UUID().uuidString).hxd")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Builders

    private func mail(_ id: String, from sender: String = "avery@example.com", body: String? = nil, sent: Date? = nil) -> [UInt8] {
        Fixture.record(strings: [sender, "Avery", "IPM.Note", "<\(id)@example.com>", "A preview of message \(id) for the test",
                                 "Topic \(id)", "Topic \(id)"], sent: sent ?? self.sent, body: body.map { "<html>\($0)</html>" })
    }

    private func noise(_ count: Int, _ byte: UInt8 = 0xAB) -> [UInt8] {
        [UInt8](repeating: byte, count: count)
    }

    private func write(_ bytes: [UInt8]) throws {
        try Data(bytes).write(to: url)
    }

    private func sorted(_ messages: [HxMailRecord]) -> [HxMailRecord] {
        messages.sorted { ($0.messageID, $0.senderAddress ?? "") < ($1.messageID, $1.senderAddress ?? "") }
    }

    /// Scans `before` to fill a cache, then `after` with and without it; both results must match.
    @discardableResult
    private func assertIncrementalMatchesFull(
        before: [UInt8], after: [UInt8], now: Date? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws -> HxStoreFile.ScanReport {
        let now = now ?? sent.addingTimeInterval(60)
        let cache = HxStoreScanCache()
        try write(before)
        _ = try HxStoreFile.scan(at: url, now: now, cache: cache)
        try write(after)
        let incremental = try HxStoreFile.scan(at: url, now: now, cache: cache)
        let full = try HxStoreFile.scan(at: url, now: now)
        XCTAssertEqual(sorted(incremental.messages), sorted(full.messages), "incremental and full scans differ", file: file, line: line)
        XCTAssertEqual(incremental.report.records, full.report.records, file: file, line: line)
        return incremental.report
    }

    private var baseFile: [UInt8] {
        Fixture.concat(Array("Nostromo".utf8), noise(37), Fixture.framed(mail("a"), id: 1), noise(101, 0x11),
                       Fixture.framed(mail("b", body: "The pilot runs six weeks."), id: 2), Fixture.framed(mail("c"), id: 3), noise(50, 0))
    }

    // MARK: - Reuse

    func test_aSecondScanOfAnUnchangedFileDecodesNothing() throws {
        let cache = HxStoreScanCache()
        try write(baseFile)
        let first = try HxStoreFile.scan(at: url, now: sent.addingTimeInterval(60), cache: cache)
        XCTAssertEqual(first.report.records, 3)
        XCTAssertEqual(first.report.reusedRecords, 0)
        let second = try HxStoreFile.scan(at: url, now: sent.addingTimeInterval(60), cache: cache)
        XCTAssertEqual(second.report.reusedRecords, 3)
        XCTAssertEqual(second.report.reusedBytes, baseFile.count - 8 - (HxStoreFile.headerSize - 1),
                       "everything after the magic up to the last offset a header fits at")
        XCTAssertEqual(sorted(second.messages), sorted(first.messages))
        XCTAssertEqual(second.messages.count, 3)
    }

    func test_aCacheOfAnotherFileIsNotUsed() throws {
        let cache = HxStoreScanCache()
        try write(baseFile)
        _ = try HxStoreFile.scan(at: url, cache: cache)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("hx-other-\(UUID().uuidString).hxd")
        defer { try? FileManager.default.removeItem(at: other) }
        try Data(baseFile).write(to: other)
        XCTAssertEqual(try HxStoreFile.scan(at: other, cache: cache).report.reusedRecords, 0)
    }

    // MARK: - Changes

    func test_aRecordAddedAtTheEndIsFoundAndTheRestReused() throws {
        let after = baseFile + Fixture.framed(mail("d"), id: 4)
        let report = try assertIncrementalMatchesFull(before: baseFile, after: after)
        XCTAssertEqual(report.records, 4)
        XCTAssertEqual(report.reusedRecords, 3)
    }

    func test_aRecordRewrittenInPlaceIsReadAgain() throws {
        // Same length, another body: only the digest can tell.
        let before = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("a", body: "Budget is 100k"), id: 1),
                                    Fixture.framed(mail("b"), id: 2))
        let after = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("a", body: "Budget is 250k"), id: 1),
                                   Fixture.framed(mail("b"), id: 2))
        XCTAssertEqual(before.count, after.count)
        let report = try assertIncrementalMatchesFull(before: before, after: after)
        XCTAssertEqual(report.reusedRecords, 1)
        try write(after)
        let cache = HxStoreScanCache()
        _ = try HxStoreFile.scan(at: url, cache: cache)
        XCTAssertEqual(try HxStoreFile.messages(at: url, cache: cache).first { $0.messageID == "<a@example.com>" }?.bodyText,
                       "Budget is 250k")
    }

    func test_aRecordWrittenIntoAGapIsFound() throws {
        let inserted = Fixture.framed(mail("g"), id: 9)
        let before = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("a"), id: 1), noise(inserted.count + 40),
                                    Fixture.framed(mail("b"), id: 2))
        let after = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("a"), id: 1), noise(20), inserted, noise(20),
                                   Fixture.framed(mail("b"), id: 2))
        XCTAssertEqual(before.count, after.count)
        let report = try assertIncrementalMatchesFull(before: before, after: after)
        XCTAssertEqual(report.records, 3)
        XCTAssertEqual(report.reusedRecords, 2)
    }

    func test_aRecordCutOffByAWriteIsFoundOnceComplete() throws {
        let record = Fixture.framed(mail("t", body: "Signed contract attached."), id: 5)
        let head = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("a"), id: 1))
        // Outlook had written the header and part of the block when the first scan ran.
        let before = head + Array(record.prefix(record.count / 2)) + noise(record.count - record.count / 2, 0)
        let after = head + record
        let report = try assertIncrementalMatchesFull(before: before, after: after)
        XCTAssertEqual(report.records, 2)
    }

    func test_aBlockCompletedPastLaterRecordsIsFound() throws {
        // A header whose block ran past the end of the file, with a whole (non-mail) record inside
        // that block. Once the file grows, the block decodes as a mail record, and a full scan
        // reads it and jumps over the record inside it. Its gap is unchanged, so only trying the
        // plausible header again finds it.
        let inner = Fixture.framed(Array(repeating: UInt8(ascii: "x"), count: 200), id: 2)
        let literals = 1000
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        var token: [UInt8] = [0xF0]
        var rest = literals - 15
        while rest >= 255 { token.append(255); rest -= 255 }
        token.append(UInt8(rest))
        let header = Fixture.concat(le32(token.count + literals), le32(literals), le32(4), [UInt8](repeating: 0, count: 8))
        let head = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("a"), id: 1))
        let before = Fixture.concat(head, header, token, noise(10), inner)
        XCTAssertLessThan(before.count - head.count - header.count - token.count, literals, "the block runs past the end")
        let outer = mail("outer")
        let after = Fixture.concat(before, outer, noise(literals))
        XCTAssertLessThan(10 + inner.count + outer.count, literals, "the outer mail lies inside the block")
        let report = try assertIncrementalMatchesFull(before: before, after: after)
        XCTAssertEqual(report.records, 2, "the first record and the outer one, never the inner one")
        let messages = try HxStoreFile.messages(at: url, now: sent.addingTimeInterval(60))
        XCTAssertTrue(messages.contains { $0.messageID == "<outer@example.com>" })
    }

    func test_aShorterFileIsReadAgainWhereItChanged() throws {
        let after = Array(baseFile.prefix(baseFile.count - 120))
        try assertIncrementalMatchesFull(before: baseFile, after: after)
    }

    func test_aFileReplacedByAnotherGivesItsMessages() throws {
        let other = Fixture.concat(Array("Nostromo".utf8), noise(13), Fixture.framed(mail("x"), id: 1), Fixture.framed(mail("y"), id: 2))
        try assertIncrementalMatchesFull(before: baseFile, after: other)
    }

    func test_aFutureTimeBecomesTheSendTimeOnceItIsPlausible() throws {
        // Read three days before its time: no send time. Read again after it: the time, as a full scan gives it.
        let file = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("f"), id: 1))
        let cache = HxStoreScanCache()
        try write(file)
        XCTAssertNil(try HxStoreFile.messages(at: url, now: sent.addingTimeInterval(-3 * 86_400), cache: cache).first?.sent)
        let later = sent.addingTimeInterval(60)
        let incremental = try HxStoreFile.messages(at: url, now: later, cache: cache)
        XCTAssertEqual(incremental, try HxStoreFile.messages(at: url, now: later))
        XCTAssertEqual(incremental.first?.sent?.timeIntervalSince1970 ?? 0, sent.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Filter

    func test_onlyMessagesSentAfterTheCutoffAreReturned() throws {
        let old = sent.addingTimeInterval(-10 * 86_400)
        let file = Fixture.concat(Array("Nostromo".utf8), Fixture.framed(mail("old", body: "Old news", sent: old), id: 1),
                                  Fixture.framed(mail("new", body: "Fresh news"), id: 2))
        try write(file)
        let messages = try HxStoreFile.messages(at: url, now: sent.addingTimeInterval(60), sentAfter: sent.addingTimeInterval(-86_400))
        XCTAssertEqual(messages.map(\.messageID), ["<new@example.com>"])
        XCTAssertEqual(messages.first?.bodyText, "Fresh news")
    }

    // MARK: - Digest

    func test_theDigestSeesEveryByteAndDependsOnTheSeed() {
        var bytes = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let digest = { (bytes: [UInt8], seed: UInt64) in bytes.withUnsafeBytes { HxStoreDigest.digest($0, 0..<bytes.count, seed: seed) } }
        let original = digest(bytes, 1)
        XCTAssertEqual(digest(bytes, 1), original)
        XCTAssertNotEqual(digest(bytes, 2), original)
        for index in [0, 7, 31, 32, 500, 998, 999] {
            var changed = bytes
            changed[index] ^= 0x01
            XCTAssertNotEqual(digest(changed, 1), original, "a flipped bit at \(index)")
        }
        bytes.append(0)
        XCTAssertNotEqual(digest(bytes, 1), original, "a longer range")
    }
}
