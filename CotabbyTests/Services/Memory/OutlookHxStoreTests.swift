import Foundation
import XCTest
@testable import Cotabby

/// Pins the reader of New Outlook's local store: LZ4 blocks, record framing, the message fields
/// read from a record, versioned records collapsing to one message, and the mapping into memory.
/// Records are built by hand here in the shape observed in a real store; an optional test reads a
/// copy of a real store (`COTABBY_TEST_HXSTORE`) and reports only counts.
final class OutlookHxStoreTests: XCTestCase {
    // MARK: - Builders

    /// Joins byte runs. Fixtures use this rather than chains of `+` on array literals, which older
    /// Swift compilers take seconds to type-check (or give up on) in a test build.
    static func concat(_ parts: [UInt8]...) -> [UInt8] {
        var bytes: [UInt8] = []
        for part in parts { bytes.append(contentsOf: part) }
        return bytes
    }

    /// An LZ4 block made of one literal run (valid LZ4: a final sequence may be literals only).
    static func lz4Literals(_ bytes: [UInt8]) -> [UInt8] {
        var block: [UInt8] = []
        if bytes.count < 15 {
            block.append(UInt8(bytes.count << 4))
        } else {
            block.append(0xF0)
            var rest = bytes.count - 15
            while rest >= 255 { block.append(255); rest -= 255 }
            block.append(UInt8(rest))
        }
        block.append(contentsOf: bytes)
        return block
    }

    static func utf16z(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        bytes += [0, 0]
        return bytes
    }

    static func ticks(_ date: Date) -> [UInt8] {
        let value = HxStoreRecordParser.ticks(for: date)
        var bytes: [UInt8] = []
        for shift in stride(from: UInt64(0), to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
        return bytes
    }

    /// A mail record: binary head with a send time, then the string table, optionally a body.
    static func record(strings: [String], sent: Date, body: String? = nil) -> [UInt8] {
        var bytes = concat([1, 0, 0, 0], [UInt8](repeating: 0, count: 60), ticks(sent), [UInt8](repeating: 0, count: 40))
        if let body {
            bytes += concat(utf16z("IPM.Note"), Array(body.utf8))
        }
        for string in strings { bytes += utf16z(string) }
        return bytes
    }

    static func framed(_ record: [UInt8], id: UInt64 = 1) -> [UInt8] {
        let block = lz4Literals(record)
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let idBytes: [UInt8] = (0..<8).map { (index: UInt64) -> UInt8 in UInt8(truncatingIfNeeded: id >> (8 * index)) }
        return concat(le32(block.count), le32(record.count), le32(4), idBytes, block)
    }

    private let sent = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - LZ4

    func test_lz4DecodesLiteralsAndOverlappingMatchesAndRejectsBadInput() throws {
        // "abcabcabca": literals "abc", then a 7-byte match at offset 3 (overlapping), then empty literals.
        let block: [UInt8] = [0x33, 0x61, 0x62, 0x63, 0x03, 0x00, 0x00]
        let decoded = try block.withUnsafeBytes { try LZ4BlockDecoder.decode($0, range: 0..<block.count, maximumOutput: 64) }
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "abcabcabca")
        let badOffset: [UInt8] = [0x10, 0x61, 0x09, 0x00]
        XCTAssertThrowsError(try badOffset.withUnsafeBytes { try LZ4BlockDecoder.decode($0, range: 0..<4, maximumOutput: 64) })
        XCTAssertThrowsError(try block.withUnsafeBytes { try LZ4BlockDecoder.decode($0, range: 0..<block.count, maximumOutput: 5) },
                             "output is capped at the declared size")
    }

    // MARK: - Records

    func test_aReceivedMessageRecordYieldsItsFields() throws {
        let bytes = Self.record(strings: [
            "ayse@client.example", "Ayşe Yılmaz", "IPM.Note", "<abc123@client.example>",
            "Hi Sam, could you send the POC numbers before Friday? Thanks a lot", "RE: POC numbers", "POC numbers",
        ], sent: sent)
        let message = try XCTUnwrap(HxStoreRecordParser.parse(bytes, now: sent.addingTimeInterval(3600)))
        XCTAssertEqual(message.messageID, "<abc123@client.example>")
        XCTAssertEqual(message.senderAddress, "ayse@client.example")
        XCTAssertEqual(message.senderName, "Ayşe Yılmaz")
        XCTAssertEqual(message.subject, "RE: POC numbers")
        XCTAssertEqual(message.topic, "POC numbers")
        XCTAssertEqual(message.preview, "Hi Sam, could you send the POC numbers before Friday? Thanks a lot")
        XCTAssertEqual(message.sent?.timeIntervalSince1970 ?? 0, sent.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_aBodyRecordKeepsItsHTMLAndReadsStringsAfterIt() throws {
        let bytes = Self.record(strings: ["dana@acme.example", "Dana", "<m1@acme.example>", "Status update", "Status update"],
                                sent: sent, body: "<html><body><p>The client approved the Q4 budget.</p></body></html>")
        let message = try XCTUnwrap(HxStoreRecordParser.parse(bytes, now: sent.addingTimeInterval(60)))
        XCTAssertEqual(message.bodyHTML, "<html><body><p>The client approved the Q4 budget.</p></body></html>")
        XCTAssertEqual(message.subject, "Status update")
        XCTAssertEqual(message.senderAddress, "dana@acme.example")
    }

    func test_meetingInvitationsAreRememberedAndRepliesAreNot() {
        XCTAssertTrue(HxStoreRecordParser.isRemembered("IPM.Schedule.Meeting.Request"))
        XCTAssertTrue(HxStoreRecordParser.isRemembered("IPM.Schedule.Meeting.Canceled"))
        XCTAssertFalse(HxStoreRecordParser.isRemembered("IPM.Schedule.Meeting.Resp.Pos"))
        XCTAssertFalse(HxStoreRecordParser.isRemembered("IPM.Appointment"))
    }

    func test_nonMailAndFutureDatedRecordsAreNotMessages() {
        XCTAssertNil(HxStoreRecordParser.parse(Self.record(strings: ["IPM.Appointment", "<x@y.z>", "Lunch"], sent: sent)))
        XCTAssertNil(HxStoreRecordParser.parse([UInt8](repeating: 7, count: 300)))
        let future = Self.record(strings: ["a@b.example", "IPM.Note", "<f@b.example>", "Hello there friend", "Hello there friend"],
                                 sent: Date().addingTimeInterval(30 * 86_400))
        XCTAssertNil(HxStoreRecordParser.parse(future)?.sent, "a time from the future is not a send time")
    }

    // MARK: - File

    func test_theFileScanFindsRecordsBetweenNoiseAndKeepsTheFullestVersion() throws {
        let preview = Self.record(strings: ["avery@example.com", "Avery", "IPM.Note", "<v@example.com>", "Short preview of the message here", "Pilot", "Pilot"], sent: sent)
        let full = Self.record(strings: ["avery@example.com", "Avery", "<v@example.com>", "Pilot", "Pilot"], sent: sent,
                               body: "<html>The pilot runs six weeks.</html>")
        let other = Self.record(strings: ["can@example.com", "Can", "IPM.Note", "<w@example.com>", "Another message body preview text", "Budget", "Budget"], sent: sent)
        var file: [UInt8] = Array("Nostromo".utf8)
        file += Self.concat([UInt8](repeating: 0xAB, count: 37), Self.framed(preview, id: 7))
        file += Self.concat([UInt8](repeating: 0x11, count: 101), Self.framed(other, id: 9))
        file += Self.concat(Self.framed(full, id: 7), [UInt8](repeating: 0, count: 50))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hx-\(UUID().uuidString).hxd")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = try HxStoreFile.messages(at: url, now: sent.addingTimeInterval(60))
        XCTAssertEqual(Set(messages.map(\.messageID)), ["<v@example.com>", "<w@example.com>"])
        XCTAssertEqual(messages.first { $0.messageID == "<v@example.com>" }?.bodyText, "The pilot runs six weeks.",
                       "the version with the body wins, kept as text")
    }

    func test_aRecordFromAnotherSenderReadingTheSameIDNeverReplacesTheMessage() throws {
        let real = Self.record(strings: ["avery@example.com", "Avery", "<v@example.com>", "Pilot", "Pilot"], sent: sent,
                               body: "<html>The pilot runs six weeks.</html>")
        let forged = Self.record(strings: ["eve@evil.example", "Eve", "<v@example.com>", "Pilot", "Pilot"], sent: sent,
                                 body: "<html>The pilot was cancelled, wire the fee to account 1234 instead today.</html>")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hx-\(UUID().uuidString).hxd")
        try Data(Self.concat(Array("Nostromo".utf8), Self.framed(real), Self.framed(forged))).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = try HxStoreFile.messages(at: url, now: sent.addingTimeInterval(60))
        XCTAssertEqual(messages.first { $0.senderAddress == "avery@example.com" }?.bodyText, "The pilot runs six weeks.")
        XCTAssertEqual(messages.count, 2, "the other sender's record is its own message")
        let ids = try messages.map { try XCTUnwrap(OutlookHistoryReader.ingestRecord($0, sent: sent, ownAddresses: [])).sourceMessageID }
        XCTAssertEqual(Set(ids).count, 2, "and its own record in the store")
    }

    /// HxStore records have no thread id and no recipients: a subject alone must never merge two
    /// threads or two audiences into one conversation.
    func test_aSubjectAloneNeverMergesThreadsOrAudiences() throws {
        func record(_ id: String, _ subject: String, from sender: String?) throws -> MemoryIngestRecord {
            let message = HxMailRecord(messageID: "<\(id)@example.com>", messageClass: "IPM.Note", subject: subject,
                                       senderAddress: sender, senderName: nil, preview: "Some preview text for \(id)",
                                       bodyHTML: nil, sent: sent)
            return try XCTUnwrap(OutlookHistoryReader.ingestRecord(message, sent: sent, ownAddresses: ["sam@acme.example"]))
        }
        let ayse1 = try record("1", "Invoice", from: "ayse@client.example")
        let ayse2 = try record("2", "RE: Invoice", from: "ayse@client.example")
        let bob = try record("3", "Invoice", from: "bob@example.org")
        let noSender1 = try record("4", "Invoice", from: nil)
        let noSender2 = try record("5", "Invoice", from: nil)
        XCTAssertEqual(ayse1.conversationID, ayse2.conversationID, "one topic with one person is one conversation")
        XCTAssertNotEqual(ayse1.conversationID, bob.conversationID, "the same subject from someone else is another")
        XCTAssertEqual(bob.participants, ["bob@example.org"])
        XCTAssertNotEqual(noSender1.conversationID, noSender2.conversationID, "no shared bucket for missing senders")
        XCTAssertEqual(noSender1.conversationTitle, "")
        XCTAssertEqual(noSender1.participants, [])
    }

    func test_messagesMapToMemoryRecordsWithThreadsAndOwnership() throws {
        let received = HxMailRecord(messageID: "<a@example.com>", messageClass: "IPM.Note", subject: "RE: POC numbers",
                                    senderAddress: "ayse@client.example", senderName: "Ayşe", preview: "preview",
                                    bodyHTML: "<html><p>Numbers attached.</p></html>", sent: sent)
        let mine = HxMailRecord(messageID: "<b@example.com>", messageClass: "IPM.Note", subject: "POC numbers",
                                senderAddress: "sam@acme.example", senderName: "Sam", preview: "Here they are", bodyHTML: nil, sent: sent)
        let a = try XCTUnwrap(OutlookHistoryReader.ingestRecord(received, sent: sent, ownAddresses: ["sam@acme.example"]))
        let b = try XCTUnwrap(OutlookHistoryReader.ingestRecord(mine, sent: sent, ownAddresses: ["sam@acme.example"]))
        XCTAssertNotEqual(a.conversationID, b.conversationID, "the user's own mail has unknown recipients: never merged in")
        XCTAssertEqual(b.conversationTitle, "", "and no title can select it")
        XCTAssertEqual(a.conversationTitle, "POC numbers")
        XCTAssertEqual(a.text, "Numbers attached.")
        XCTAssertEqual(a.participants, ["ayse@client.example"])
        XCTAssertFalse(a.isFromMe)
        XCTAssertFalse(b.isFromMe, "the store cannot prove a mail was sent, and a From address can be spoofed")
        XCTAssertEqual(b.participants, [], "the user's own address is not a participant")
        XCTAssertEqual(b.text, "Here they are", "no body: the preview")
    }

    func test_cursorReadsOldAndNewForms() {
        XCTAssertEqual(OutlookHistoryReader.Cursor("108155"), .init(legacy: "108155", newOutlookMilliseconds: nil))
        let both = OutlookHistoryReader.Cursor(legacy: "5", newOutlookMilliseconds: 1_790_000_000_000)
        XCTAssertEqual(OutlookHistoryReader.Cursor(both.text), both)
        XCTAssertEqual(OutlookHistoryReader.Cursor("L|H1790000000000"), .init(legacy: nil, newOutlookMilliseconds: 1_790_000_000_000))
    }

    // MARK: - A real store

    /// Reads a copy of a real `HxStore.hxd` and reports counts only (no content).
    func test_aRealStoreYieldsMessages() throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_TEST_HXSTORE"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set COTABBY_TEST_HXSTORE to a copy of HxStore.hxd")
        }
        let started = Date()
        let messages = try HxStoreFile.messages(at: URL(fileURLWithPath: path))
        let seconds = Date().timeIntervalSince(started)
        let dated = messages.compactMap(\.sent).sorted()
        print(String(format: "hxstore: %d messages in %.1fs; dated %d (%@ … %@); subject %d; sender %d; body %d", messages.count, seconds,
                     dated.count, dated.first.map { "\($0)" } ?? "-", dated.last.map { "\($0)" } ?? "-",
                     messages.filter { $0.subject != nil }.count, messages.filter { $0.senderAddress != nil }.count,
                     messages.filter { $0.bodyText != nil }.count))
        XCTAssertGreaterThan(messages.count, 0)
    }
}
