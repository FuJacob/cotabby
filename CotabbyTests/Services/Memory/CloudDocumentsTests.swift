import Compression
import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins the cloud-drive document sources: reading ZIP archives safely, the text of Word, PowerPoint
/// and Excel files, splitting documents into sections, the reader's records and cursor, and memory
/// forgetting a document's lost sections and deleted files while documents ignore retention.
final class CloudDocumentsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Builders

    /// A ZIP archive with the given entries, each DEFLATE-compressed unless `stored`.
    static func zip(_ entries: [(name: String, text: String)], stored: Bool = false) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: value >> (8 * index)) } }
        // Each header is joined from its fields with `append(contentsOf:)`: a long chain of `+` on
        // arrays takes older Swift compilers seconds to type-check in a test build.
        func join(_ fields: [[UInt8]]) -> [UInt8] { fields.flatMap { $0 } }
        var body: [UInt8] = []
        var directory: [UInt8] = []
        for entry in entries {
            let raw = Array(entry.text.utf8)
            var data = raw
            if !stored {
                var buffer = [UInt8](repeating: 0, count: raw.count + 1024)
                let size = compression_encode_buffer(&buffer, buffer.count, raw, raw.count, nil, COMPRESSION_ZLIB)
                data = Array(buffer.prefix(size))
            }
            let name = Array(entry.name.utf8)
            let method = stored ? 0 : 8
            let offset = body.count
            body.append(contentsOf: join([
                le32(0x0403_4B50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                le32(data.count), le32(raw.count), le16(name.count), le16(0), name, data
            ]))
            directory.append(contentsOf: join([
                le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                le32(data.count), le32(raw.count), le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0),
                le32(offset), name
            ]))
        }
        let end = join([
            le32(0x0605_4B50), le16(0), le16(0), le16(entries.count), le16(entries.count),
            le32(directory.count), le32(body.count), le16(0)
        ])
        return Data(join([body, directory, end]))
    }

    // MARK: - ZIP

    func test_zipEntriesReadStoredAndDeflatedAndBadArchivesThrow() throws {
        let text = String(repeating: "Pilot scope and pricing. ", count: 40)
        for stored in [true, false] {
            let archive = try ZipArchiveReader(data: Self.zip([("a.xml", "<x/>"), ("b.xml", text)], stored: stored))
            XCTAssertEqual(archive.names, ["a.xml", "b.xml"])
            XCTAssertEqual(try archive.contents(of: "b.xml").map { String(decoding: $0, as: UTF8.self) }, text)
            XCTAssertNil(try archive.contents(of: "missing.xml"))
        }
        XCTAssertThrowsError(try ZipArchiveReader(data: Data("not a zip at all, just text".utf8)))
        var truncated = Self.zip([("b.xml", text)])
        truncated.removeSubrange(10..<40)
        XCTAssertThrowsError(try ZipArchiveReader(data: truncated).contents(of: "b.xml"), "a damaged archive throws, never traps")
    }

    func test_anEntryClaimingAHugeExpansionIsRefused() throws {
        var data = Self.zip([("bomb.xml", String(repeating: "a", count: 5_000))])
        // Rewrite the central directory's uncompressed size to 1 GB.
        let central = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        data.replaceSubrange((central + 24)..<(central + 28), with: [0x00, 0x00, 0x00, 0x40])
        let archive = try ZipArchiveReader(data: data)
        XCTAssertThrowsError(try archive.contents(of: "bomb.xml")) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ZipError, .tooLarge)
        }
    }

    // MARK: - Office text

    func test_officeFilesYieldTheirTextInOrder() throws {
        let word = Self.zip([("word/document.xml", """
        <w:document><w:body><w:p><w:r><w:t>Pilot runs</w:t></w:r><w:r><w:t xml:space="preserve"> six weeks.</w:t></w:r></w:p>\
        <w:p><w:r><w:t>Budget approved.</w:t></w:r></w:p></w:body></w:document>
        """)])
        XCTAssertEqual(try OfficeDocumentText.text(of: word, kind: .word), "Pilot runs six weeks.\nBudget approved.")

        let slide = { (text: String) in "<p:sld><p:cSld><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:cSld></p:sld>" }
        let deck = Self.zip([("ppt/slides/slide10.xml", slide("Ten")), ("ppt/slides/slide2.xml", slide("Two")),
                             ("ppt/notesSlides/notesSlide2.xml", slide("Speaker note"))])
        XCTAssertEqual(try OfficeDocumentText.text(of: deck, kind: .powerPoint), "Two\n\nTen\n\nSpeaker note",
                       "slides in number order, then notes")

        let sheet = Self.zip([("xl/sharedStrings.xml", "<sst><si><t>Customer</t></si><si><r><t>Acme </t></r><r><t>Corp</t></r></si></sst>")])
        XCTAssertEqual(try OfficeDocumentText.text(of: sheet, kind: .excel), "Customer\nAcme Corp")
    }

    /// One budget for the whole file: a deck of many slides stops at the character cap overall,
    /// not per slide.
    func test_aDocumentsTextBudgetCoversAllItsParts() throws {
        let big = String(repeating: "word ", count: 40_000)  // 200,000 characters per slide
        let slide = "<p:sld><a:p><a:r><a:t>\(big)</a:t></a:r></a:p></p:sld>"
        let deck = Self.zip((1...6).map { ("ppt/slides/slide\($0).xml", slide) })
        let text = try OfficeDocumentText.text(of: deck, kind: .powerPoint)
        XCTAssertLessThanOrEqual(text.count, OfficeDocumentText.maximumCharacters)
    }

    // MARK: - Sections

    func test_sectionsPackParagraphsAndCutLongOnesAtSentences() {
        XCTAssertEqual(DocumentSections.split("First paragraph is here.\n\nSecond   one\nwraps lines."),
                       ["First paragraph is here. Second one wraps lines."])
        let sentence = "This sentence is about forty characters. "
        let long = String(repeating: sentence, count: 100)
        let sections = DocumentSections.split(long)
        XCTAssertGreaterThan(sections.count, 1)
        XCTAssertTrue(sections.allSatisfy { $0.count <= DocumentSections.maximumCharacters })
        XCTAssertTrue(sections.dropLast().allSatisfy { $0.hasSuffix(".") }, "cut at sentence ends")
        XCTAssertEqual(DocumentSections.split("tiny"), [], "near-empty text is not a section")
    }

    // MARK: - Reader

    private func drive(_ roots: [URL]) -> CloudDriveReader {
        CloudDriveReader(drive: .init(id: "google_drive", title: "Google Drive", roots: { roots }))
    }

    func test_theReaderReadsDocumentsAsWholeConversationsAndListsWhatExists() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Clients"), withIntermediateDirectories: true)
        try Data("Acme pilot notes: the pilot runs six weeks from November.".utf8)
            .write(to: root.appendingPathComponent("Clients/Acme.md"))
        try Self.zip([("word/document.xml", "<w:document><w:p><w:t>Pricing is per endpoint per month.</w:t></w:p></w:document>")])
            .write(to: root.appendingPathComponent("Pricing.docx"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("Plan.gdoc"))

        let reader = drive([root])
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 400)
        let prefix = "GoogleDrive-me@example.com/"
        XCTAssertEqual(Set(page.records.map(\.conversationID)), [prefix + "Clients/Acme.md", prefix + "Pricing.docx"])
        XCTAssertEqual(page.completeConversations, [prefix + "Clients/Acme.md", prefix + "Pricing.docx"])
        let pricing = try XCTUnwrap(page.records.first { $0.conversationTitle == "Pricing" })
        XCTAssertEqual(pricing.text, "Pricing is per endpoint per month.")
        XCTAssertFalse(pricing.isFromMe, "a shared document is not the user's own words")
        XCTAssertEqual(pricing.sender, "")
        XCTAssertEqual(reader.liveConversationIDs(), [prefix + "Clients/Acme.md", prefix + "Pricing.docx"])

        let again = try reader.read(after: page.nextCursor, since: nil, limit: 400)
        XCTAssertTrue(again.records.isEmpty, "nothing changed since the cursor")
        XCTAssertEqual(drive([]).readiness(), .notFound("Google Drive is not set up on this Mac."))
        XCTAssertNil(drive([]).liveConversationIDs(), "an unreadable drive never reads as everything deleted")
    }

    /// A file that cannot be read (an online-only file while offline) is not left behind the
    /// cursor: the next sync tries it again, even though it has not changed.
    func test_anUnreadableFileIsTriedAgainOnTheNextSync() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let offline = root.appendingPathComponent("Offline.md")
        try Data("Notes from the offline file about the pilot.".utf8).write(to: offline)
        try Data("Another readable file about pricing tiers.".utf8).write(to: root.appendingPathComponent("Online.md"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: offline.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: offline.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: offline.path) }

        let reader = drive([root])
        let first = try reader.read(after: nil, since: nil, limit: 400)
        XCTAssertEqual(first.records.map(\.conversationTitle), ["Online"])
        let stillOffline = try reader.read(after: first.nextCursor, since: nil, limit: 400)
        XCTAssertTrue(stillOffline.records.isEmpty)
        XCTAssertEqual(CloudDriveReader.Cursor(stillOffline.nextCursor ?? first.nextCursor).retry,
                       ["GoogleDrive-me@example.com/Offline.md"], "still waiting to be read")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: offline.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: offline.path)
        let next = try reader.read(after: stillOffline.nextCursor ?? first.nextCursor, since: nil, limit: 400)
        XCTAssertEqual(next.records.map(\.conversationTitle), ["Offline"], "the next sync reads it")
        XCTAssertEqual(CloudDriveReader.Cursor(next.nextCursor).retry, [])
        XCTAssertTrue(try reader.read(after: next.nextCursor, since: nil, limit: 400).records.isEmpty)
        XCTAssertEqual(CloudDriveReader.Cursor("1790000000.0"), CloudDriveReader.Cursor(after: 1_790_000_000), "older cursors still read")
    }

    /// A file the drive still holds right after the read ("in use") is given back again a moment
    /// later; other errors are not retried.
    func test_onlyABusyFileIsGivenBackAgain() {
        let busy = NSError(domain: NSCocoaErrorDomain, code: 255, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        ])
        XCTAssertTrue(DocumentTextExtractor.isBusy(busy))
        XCTAssertTrue(DocumentTextExtractor.isBusy(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))))
        XCTAssertFalse(DocumentTextExtractor.isBusy(NSError(domain: NSCocoaErrorDomain, code: 257)))
    }

    /// A sync whose last page has nothing left to read (the file it stopped before is gone) still
    /// hands the failures of its earlier pages to the next sync.
    func test_failuresReachTheNextSyncWhenTheLastPageIsEmpty() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, time) in [("Locked.md", 1_000.0), ("Read.md", 2_000), ("Gone.md", 3_000)] {
            try Data("A document long enough to be a section, \(name).".utf8).write(to: root.appendingPathComponent(name))
            try stamp(name, in: root, modified: time)
        }
        let locked = root.appendingPathComponent("Locked.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let reader = drive([root])

        let first = try reader.read(after: nil, since: nil, limit: 1)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(CloudDriveReader.Cursor(first.nextCursor).failed, ["GoogleDrive-me@example.com/Locked.md"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone.md"))
        let last = try reader.read(after: first.nextCursor, since: nil, limit: 1)
        XCTAssertFalse(last.hasMore)
        let cursor = CloudDriveReader.Cursor(last.nextCursor ?? first.nextCursor)
        XCTAssertEqual(cursor.retry, ["GoogleDrive-me@example.com/Locked.md"], "tried again next sync")
        XCTAssertEqual(cursor.failed, [])
    }

    /// A file read with no text in it (a scanned PDF, an empty note) is done until it changes: it is
    /// not read again on every sync, which for an online-only file meant downloading it each time.
    func test_aFileWithNoTextIsNotReadAgainUntilItChanges() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.blankPDF().write(to: root.appendingPathComponent("Scan.pdf"))
        try Data().write(to: root.appendingPathComponent("Empty.md"))
        try stamp("Scan.pdf", in: root, modified: 1_000)
        try stamp("Empty.md", in: root, modified: 1_000)
        let attributes = FakeFileAttributes()
        attributes.set("Scan.pdf", arrival: 1_000)
        attributes.set("Empty.md", arrival: 1_000)
        var reader = drive([root])
        reader.arrival = { url, _, _ in attributes.arrival(url) }

        let first = try reader.read(after: nil, since: nil, limit: 400)
        XCTAssertTrue(first.records.isEmpty)
        let prefix = "GoogleDrive-me@example.com/"
        XCTAssertEqual(first.completeConversations, [prefix + "Scan.pdf", prefix + "Empty.md"], "what an earlier version held goes")
        XCTAssertEqual(CloudDriveReader.Cursor(first.nextCursor).retry, [], "not tried again")

        // Given back to the cloud after the read: its status-change time moves, which is no change.
        attributes.set("Scan.pdf", arrival: 5_000)
        let again = try reader.read(after: first.nextCursor, since: nil, limit: 400)
        XCTAssertNil(again.nextCursor, "nothing to read")

        try Data("Now the note has text about the pilot.".utf8).write(to: root.appendingPathComponent("Empty.md"))
        try stamp("Empty.md", in: root, modified: 6_000)
        attributes.set("Empty.md", arrival: 6_000)
        let edited = try reader.read(after: first.nextCursor, since: nil, limit: 400)
        XCTAssertEqual(edited.records.map(\.conversationTitle), ["Empty"], "a change reads it again")
    }

    /// A one-page PDF with nothing on it, as a scan without a text layer reads.
    static func blankPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A sync lists the drive once: the files that still exist are the listing its read took, and a
    /// later call lists again.
    func test_theListingOfARead() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("A document long enough to be a section.".utf8).write(to: root.appendingPathComponent("Doc.md"))
        try Data("Another document long enough to be one.".utf8).write(to: root.appendingPathComponent("Other.md"))
        let reader = drive([root])
        _ = try reader.read(after: nil, since: nil, limit: 400)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Other.md"))
        XCTAssertEqual(reader.liveConversationIDs()?.count, 2, "the read's listing")
        XCTAssertEqual(reader.liveConversationIDs(), ["GoogleDrive-me@example.com/Doc.md"], "taken once, then listed afresh")
    }

    /// A file's status-change time moves when its content is downloaded or given back (by this
    /// reader, the user or the drive) and when the drive updates its records: for a file seen
    /// before, only a new modification time is a change, or every sync would download unchanged
    /// files again. A file not seen before still arrives by its status-change time, so one moved in
    /// with an old date is read. File Provider placeholders cannot be made in a test, so arrival
    /// times come from a fake.
    private func stamp(_ name: String, in root: URL, modified: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)],
                                              ofItemAtPath: root.appendingPathComponent(name).path)
    }

    func test_aSeenFileChangesOnlyWhenModifiedAndANewOneArrives() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Quarterly plan notes for the pilot rollout.".utf8).write(to: root.appendingPathComponent("Plan.md"))
        let attributes = FakeFileAttributes()
        try stamp("Plan.md", in: root, modified: 1_000)
        attributes.set("Plan.md", arrival: 1_000)
        var reader = drive([root])
        reader.arrival = { url, _, _ in attributes.arrival(url) }

        let first = try reader.read(after: nil, since: nil, limit: 400)
        XCTAssertEqual(first.records.map(\.conversationTitle), ["Plan"])
        let id = "GoogleDrive-me@example.com/Plan.md"
        XCTAssertEqual(CloudDriveReader.Cursor(first.nextCursor).seen, [CloudDriveReader.Cursor.seenKey(id)])

        // Downloaded, given back, or touched by the drive: its status-change time moves on.
        attributes.set("Plan.md", arrival: 5_000)
        XCTAssertNil(try reader.read(after: first.nextCursor, since: nil, limit: 400).nextCursor, "not a change")

        // A file moved in with an old modification date still arrives.
        try Data("Pricing tiers for the starter and team plans.".utf8).write(to: root.appendingPathComponent("Pricing.md"))
        try stamp("Pricing.md", in: root, modified: 500)
        attributes.set("Pricing.md", arrival: 6_000)
        let moved = try reader.read(after: first.nextCursor, since: nil, limit: 400)
        XCTAssertEqual(moved.records.map(\.conversationTitle), ["Pricing"])
        XCTAssertEqual(CloudDriveReader.Cursor(moved.nextCursor).seen?.count, 2)

        // Edited: a newer modification time brings it back.
        try stamp("Plan.md", in: root, modified: 7_000)
        attributes.set("Plan.md", arrival: 7_000)
        let edited = try reader.read(after: moved.nextCursor, since: nil, limit: 400)
        XCTAssertEqual(edited.records.map(\.conversationTitle), ["Plan"])

        // Downloaded by the user later: unchanged, not read again.
        attributes.set("Pricing.md", arrival: 8_000)
        XCTAssertNil(try reader.read(after: edited.nextCursor, since: nil, limit: 400).nextCursor)
    }

    /// A cursor from before `seen` existed: the files listed now count as seen, so the update does
    /// not read the whole drive again, and the listing is stored for the next sync.
    func test_aCursorWithoutSeenFilesTakesTheCurrentListing() throws {
        let root = directory.appendingPathComponent("GoogleDrive-me@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Quarterly plan notes for the pilot rollout.".utf8).write(to: root.appendingPathComponent("Plan.md"))
        try stamp("Plan.md", in: root, modified: 1_000)
        let attributes = FakeFileAttributes()
        attributes.set("Plan.md", arrival: 9_000)
        var reader = drive([root])
        reader.arrival = { url, _, _ in attributes.arrival(url) }

        let upgraded = try reader.read(after: #"{"after":2000,"evicted":["ab"],"retry":[]}"#, since: nil, limit: 400)
        XCTAssertTrue(upgraded.records.isEmpty, "a status change alone does not read a file the old cursor covered")
        let cursor = CloudDriveReader.Cursor(upgraded.nextCursor)
        XCTAssertEqual(cursor.after, 2_000)
        XCTAssertEqual(cursor.seen, [CloudDriveReader.Cursor.seenKey("GoogleDrive-me@example.com/Plan.md")])

        try Data("Pricing tiers for the starter and team plans.".utf8).write(to: root.appendingPathComponent("Pricing.md"))
        try stamp("Pricing.md", in: root, modified: 500)
        attributes.set("Pricing.md", arrival: 9_500)
        XCTAssertEqual(try reader.read(after: upgraded.nextCursor, since: nil, limit: 400).records.map(\.conversationTitle), ["Pricing"])
    }

    func test_cursorFormsReadAndWrite() {
        XCTAssertEqual(CloudDriveReader.Cursor("1790000000.0"), CloudDriveReader.Cursor(after: 1_790_000_000), "the plain form")
        XCTAssertEqual(CloudDriveReader.Cursor(#"{"after":12,"retry":["x"]}"#), CloudDriveReader.Cursor(after: 12, retry: ["x"]))
        XCTAssertEqual(CloudDriveReader.Cursor(after: 3).encoded, "3.0", "nothing pending: the plain form")
        let keys: Set<UInt64> = [0, 1, .max, CloudDriveReader.Cursor.seenKey("GoogleDrive-a/Doc.md")]
        let full = CloudDriveReader.Cursor(after: 7, retry: ["r"], failed: ["f"], seen: keys)
        XCTAssertEqual(CloudDriveReader.Cursor(full.encoded), full)
        XCTAssertNil(CloudDriveReader.Cursor.decodeKeys("not base64!"))
    }

    /// One account (or folder) that cannot be read makes the listing incomplete, and an incomplete
    /// listing removes nothing: the readable account's documents do not make the other's look deleted.
    func test_aPartlyUnreadableDriveRemovesNothing() throws {
        let first = directory.appendingPathComponent("GoogleDrive-a@example.com", isDirectory: true)
        let second = directory.appendingPathComponent("GoogleDrive-b@example.com", isDirectory: true)
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("A document long enough to be a section.".utf8).write(to: root.appendingPathComponent("Doc.md"))
        }
        let reader = drive([first, second])
        XCTAssertEqual(reader.liveConversationIDs()?.count, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: second.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path) }
        XCTAssertEqual(reader.readiness(), .ready, "one readable account is enough to sync")
        XCTAssertNil(reader.liveConversationIDs())
    }

    /// A huge paragraph is cut in time proportional to its length and stops at the section limit.
    func test_aHugeParagraphIsCutQuicklyAndBounded() {
        let started = Date()
        let sections = DocumentSections.split(String(repeating: "x", count: 1_000_000))
        XCTAssertEqual(sections.count, DocumentSections.maximumSections)
        XCTAssertTrue(sections.allSatisfy { $0.count == DocumentSections.maximumCharacters })
        let shorter = DocumentSections.split(String(repeating: "word ", count: 80_000))
        XCTAssertGreaterThan(shorter.count, 260)
        XCTAssertTrue(shorter.allSatisfy { $0.count <= DocumentSections.maximumCharacters })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func test_cloudStorageFoldersAreTheProvidersAccountsWithoutTrash() throws {
        for name in ["GoogleDrive-a@example.com", "GoogleDrive-b@example.org", "OneDrive-example.com", "OneDrive-SharedLibraries-x - .Trash"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(CloudDriveReader.cloudStorageFolders(prefix: "GoogleDrive-", root: directory.path).map(\.lastPathComponent),
                       ["GoogleDrive-a@example.com", "GoogleDrive-b@example.org"])
        XCTAssertEqual(CloudDriveReader.cloudStorageFolders(prefix: "OneDrive-", root: directory.path).map(\.lastPathComponent),
                       ["OneDrive-example.com"])
    }

    // MARK: - Store

    private func record(_ conversation: String, _ number: Int, _ text: String, at date: Date = Date()) -> MemoryIngestRecord {
        MemoryIngestRecord(sourceMessageID: "\(conversation)#\(number)", conversationID: conversation, conversationTitle: conversation,
                           sender: "", isFromMe: false, timestamp: date, text: text, participants: [], subject: nil)
    }

    func test_aShortenedDocumentLosesItsTailAndADeletedOneIsForgotten() throws {
        let store = try MemoryStore(path: directory.appendingPathComponent("m.sqlite"), vault: MemoryVault(rootKey: SymmetricKey(data: Data(0..<32))))
        try store.upsert(source: "google_drive", records: [record("A.md", 0, "one"), record("A.md", 1, "two"), record("B.md", 0, "bee")])
        let keep = store.recordID(source: "google_drive", sourceMessageID: "A.md#0")
        let removed = try store.removeRecords(source: "google_drive", inConversations: ["A.md"], notIn: [keep])
        XCTAssertEqual(removed, [store.recordID(source: "google_drive", sourceMessageID: "A.md#1")])
        XCTAssertEqual(try store.sourceStats("google_drive").messages, 2)

        let gone = try store.removeConversations(source: "google_drive", notIn: ["A.md"])
        XCTAssertEqual(gone, [store.recordID(source: "google_drive", sourceMessageID: "B.md#0")])
        XCTAssertEqual(try store.sourceStats("google_drive").conversations, 1)
    }

    func test_retentionSkipsDocumentSources() throws {
        let store = try MemoryStore(path: directory.appendingPathComponent("m.sqlite"), vault: MemoryVault(rootKey: SymmetricKey(data: Data(0..<32))))
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try store.upsert(source: "google_drive", records: [record("Handbook.pdf", 0, "old handbook", at: old)])
        try store.upsert(source: "whatsapp", records: [record("chat", 0, "old chat", at: old)])
        let purged = try store.purge(excludedConversations: [], excludedParticipants: [], olderThan: Date().timeIntervalSince1970,
                                     keepingAllOf: MemorySourceCatalog.sourcesKeepingAllDates)
        XCTAssertEqual(purged, 1, "the old chat goes, the old document stays")
        XCTAssertEqual(try store.sourceStats("google_drive").messages, 1)
        XCTAssertTrue(MemorySourceCatalog.keepsAllDates("onedrive"))
        XCTAssertFalse(MemorySourceCatalog.keepsAllDates("apple_mail"))
    }
}

/// Arrival times a test sets per file name, standing in for a File Provider drive.
private final class FakeFileAttributes: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [String: Double] = [:]

    /// The modification time is the real file's (the listing reads it from disk), set by `stamp`.
    func set(_ name: String, arrival: Double) {
        lock.lock()
        defer { lock.unlock() }
        arrivals[name] = arrival
    }

    func arrival(_ url: URL) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return arrivals[url.lastPathComponent] ?? 0
    }
}
