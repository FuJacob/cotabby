import Foundation
import SQLite3
import XCTest
@testable import Cotabby

/// Pins the readers of protected stores against fixture databases with the same tables WhatsApp
/// and Mail use: what becomes a record, who the participants are, how cursors advance, which
/// messages are skipped, and that an unrecognized layout is refused rather than misread.
final class MemoryHistoryReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase(_ path: String, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    // MARK: - WhatsApp

    private func whatsAppFixture() throws -> WhatsAppHistoryReader {
        let path = directory.appendingPathComponent("ChatStorage.sqlite").path
        // Apple-epoch dates: 810000000 is 2026-09-01.
        try makeDatabase(path, """
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR, ZSESSIONTYPE INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEMBERJID VARCHAR, ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTEXT VARCHAR, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP,
            ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER, ZSTANZAID VARCHAR, ZPUSHNAME VARCHAR, ZGROUPEVENTTYPE INTEGER);
        INSERT INTO ZWACHATSESSION VALUES (1, '15550100001@s.whatsapp.net', 'Ayşe', 0), (2, '12036@g.us', 'Trip', 1),
            (3, 'status@broadcast', 'Status', 3);
        INSERT INTO ZWAGROUPMEMBER VALUES (10, 2, '15550100001@s.whatsapp.net', 'Ayşe', 'Ayşe'), (11, 2, '15550100002@s.whatsapp.net', NULL, 'Can');
        INSERT INTO ZWAMESSAGE VALUES
            (1, 'the invoice is paid', 0, 810000000, 1, NULL, 'A1', NULL, 0),
            (2, 'thanks!', 1, 810000100, 1, NULL, 'A2', NULL, 0),
            (3, 'budget is fixed', 0, 810000200, 2, 11, 'G1', 'Can P', 0),
            (4, NULL, 0, 810000300, 1, NULL, 'A3', NULL, 0),
            (5, 'Can joined', 0, 810000400, 2, NULL, 'G2', NULL, 1),
            (6, 'my status', 1, 810000500, 3, NULL, 'S1', NULL, 0),
            (7, printf('%.*c', 20000, 'x'), 0, 810000600, 1, NULL, 'A4', NULL, 0);
        """)
        return WhatsAppHistoryReader(databasePath: path)
    }

    func test_whatsAppReadsTextFromChatsAndGroupsWithJIDParticipants() throws {
        let reader = try whatsAppFixture()
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 100)

        XCTAssertEqual(page.records.prefix(3).map(\.text), ["the invoice is paid", "thanks!", "budget is fixed"])
        XCTAssertEqual(page.records.last?.text.count, EmailBodyExtractor.maximumCharacters, "huge messages are capped")
        let first = page.records[0]
        XCTAssertEqual(first.conversationID, "15550100001@s.whatsapp.net")
        XCTAssertEqual(first.conversationTitle, "Ayşe")
        XCTAssertEqual(first.sender, "Ayşe")
        XCTAssertEqual(first.participants, ["15550100001@s.whatsapp.net"])
        XCTAssertEqual(first.timestamp.timeIntervalSince1970, 810000000 + WhatsAppHistoryReader.appleEpochOffset)
        XCTAssertTrue(page.records[1].isFromMe)
        let group = page.records[2]
        XCTAssertEqual(group.sender, "Can")
        XCTAssertEqual(Set(group.participants), ["15550100001@s.whatsapp.net", "15550100002@s.whatsapp.net",
                                                 WhatsAppHistoryReader.groupMarker + "12036@g.us"],
                       "a group carries its marker, so it never has exactly a 1:1 chat's people")
        // The cursor is the last row returned; rows the query skips (no text, system events, status)
        // are simply re-checked by the next read.
        XCTAssertEqual(page.nextCursor, "7")
        XCTAssertFalse(page.hasMore)
    }

    func test_whatsAppResumesAfterTheCursorAndPages() throws {
        let reader = try whatsAppFixture()
        let first = try reader.read(after: nil, since: nil, limit: 2)
        XCTAssertTrue(first.hasMore)
        let rest = try reader.read(after: first.nextCursor, since: nil, limit: 10)
        XCTAssertEqual(rest.records.first?.text, "budget is fixed")
    }

    func test_anUnrecognizedLayoutIsRefused() throws {
        let path = directory.appendingPathComponent("Other.sqlite").path
        try makeDatabase(path, "CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZBODY TEXT);")
        if case .failed = WhatsAppHistoryReader(databasePath: path).readiness() {} else {
            XCTFail("a different layout must be refused")
        }
        XCTAssertEqual(WhatsAppHistoryReader(databasePath: path + ".missing").readiness().isReady, false)
    }

    // MARK: - Apple Mail

    func test_mailUsesSummariesOrEmlxAndKnowsWhichMailIsMine() throws {
        let root = directory.appendingPathComponent("V10")
        let mailData = root.appendingPathComponent("MailData")
        let messages = root.appendingPathComponent("ACCOUNT/INBOX.mbox/UUID/Data/Messages")
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let emlxBody = "Content-Type: text/plain\r\n\r\nNumbers look great, see you Friday."
        try Data("\(emlxBody.utf8.count)\n\(emlxBody)".utf8).write(to: messages.appendingPathComponent("2.emlx"))
        try makeDatabase(mailData.appendingPathComponent("Envelope Index").path, """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject INTEGER, summary INTEGER,
            date_received INTEGER, mailbox INTEGER, deleted INTEGER, conversation_id INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCOUNT/INBOX'), (2, 'imap://ACCOUNT/Sent%20Messages');
        INSERT INTO addresses VALUES (1, 'Me@Example.com', 'Sam'), (2, 'ayse@example.com', 'Ayşe Yılmaz');
        INSERT INTO subjects VALUES (1, 'POC results');
        INSERT INTO summaries VALUES (1, 'Could you send the POC numbers before the call on Thursday please?');
        INSERT INTO messages VALUES
            (1, 1, 1, 1, 1790000000, 2, 0, 77),
            (2, 2, 1, NULL, 1790000500, 1, 0, 77),
            (3, 2, 1, NULL, 1790000900, 1, 1, 77);
        INSERT INTO recipients VALUES (1, 1, 2, 0, 0), (2, 2, 1, 0, 0);
        """)
        let reader = AppleMailHistoryReader(mailRoot: root.path)
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 50)

        XCTAssertEqual(page.records.count, 2, "the deleted message is skipped")
        let mine = page.records[0]
        XCTAssertTrue(mine.isFromMe)
        XCTAssertEqual(mine.text, "Could you send the POC numbers before the call on Thursday please?")
        XCTAssertEqual(mine.participants, ["ayse@example.com"])
        XCTAssertEqual(mine.conversationID, "77|ayse@example.com")
        XCTAssertEqual(mine.subject, "POC results")
        let theirs = page.records[1]
        XCTAssertFalse(theirs.isFromMe)
        XCTAssertEqual(theirs.sender, "Ayşe Yılmaz")
        XCTAssertEqual(theirs.text, "Numbers look great, see you Friday.")
        XCTAssertEqual(theirs.participants, ["ayse@example.com"])
        XCTAssertEqual(theirs.conversationID, mine.conversationID, "the same thread with the same people")
    }

    /// Only mail the user actually sent is theirs: a mail in the inbox that merely shows the user's
    /// address as its sender (spoofed) is not, a Sent label is, and another copy of a sent message
    /// is skipped rather than trusted by its reusable Message-ID. Junk is not read.
    func test_mailIsMineOnlyWhenItWasSent() throws {
        let root = directory.appendingPathComponent("V10")
        let mailData = root.appendingPathComponent("MailData")
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        try makeDatabase(mailData.appendingPathComponent("Envelope Index").path, """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, sender INTEGER, subject INTEGER, summary INTEGER,
            date_received INTEGER, mailbox INTEGER, deleted INTEGER, conversation_id INTEGER);
        CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCOUNT/INBOX'), (2, 'imap://ACCOUNT/Sent%20Messages'),
            (3, 'imap://GMAIL/%5BGmail%5D/All%20Mail'), (4, 'imap://GMAIL/%5BGmail%5D/Sent%20Mail'), (5, 'imap://ACCOUNT/Junk'),
            (6, 'imap://ACCOUNT/Presentations'), (7, 'imap://sent.example.com/INBOX');
        INSERT INTO addresses VALUES (1, 'me@example.com', 'Sam');
        INSERT INTO subjects VALUES (1, 'Budget');
        INSERT INTO summaries VALUES (1, 'The budget for the pilot is approved and final now.');
        INSERT INTO messages VALUES
            (1, 501, 1, 1, 1, 1790000000, 2, 0, 9),
            (2, 501, 1, 1, 1, 1790000000, 1, 0, 9),
            (3, 502, 1, 1, 1, 1790000100, 3, 0, 9),
            (4, 503, 1, 1, 1, 1790000200, 1, 0, 9),
            (5, 504, 1, 1, 1, 1790000300, 5, 0, 9),
            (6, 505, 1, 1, 1, 1790000400, 6, 0, 9),
            (7, 506, 1, 1, 1, 1790000500, 7, 0, 9);
        INSERT INTO labels VALUES (3, 4);
        """)
        let page = try AppleMailHistoryReader(mailRoot: root.path).read(after: nil, since: nil, limit: 50)
        XCTAssertEqual(page.records.map(\.sourceMessageID), ["1", "3", "4", "6", "7"],
                       "the inbox copy of a sent message (2) and junk (5) are skipped")
        XCTAssertEqual(page.records.map(\.isFromMe), [true, true, false, false, false],
                       "Sent mailbox and Sent label are mine; the address alone, or \"sent\" elsewhere in the URL, is not")
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "ews://X/G%C3%B6nderilmi%C5%9F%20%C3%96%C4%9Feler"), .sent)
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "imap://X/%C4%B0stenmeyen%20E-posta"), .junk)
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "imap://X/Consent%20forms"), .other)
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "imap://X/Junk/Phishing"), .junk, "anything under junk")
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "imap://X/Bulk%20Mail"), .junk)
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "imap://spam-filter.example.com/Sent"), .sent, "the host is not a folder")
        XCTAssertEqual(AppleMailHistoryReader.role(ofMailboxURL: "local:///Sent%20Messages"), .sent)
    }

    func test_mailSubjectsLoseReplyPrefixes() {
        XCTAssertEqual(AppleMailHistoryReader.baseSubject("Re: Fwd: POC results"), "POC results")
        XCTAssertEqual(AppleMailHistoryReader.baseSubject("YNT: Teklif"), "Teklif")
        XCTAssertEqual(AppleMailHistoryReader.baseSubject("Reminder: invoice"), "Reminder: invoice")
    }

    func test_mailWithoutAThreadIsAConversationOfItsOwn() {
        XCTAssertEqual(AppleMailHistoryReader.conversationID(thread: 0, rowID: 1, people: ["ayse@example.com"]), "message-1")
        XCTAssertEqual(AppleMailHistoryReader.conversationID(thread: nil, rowID: 2, people: ["ayse@example.com"]), "message-2")
    }

    /// Mail threads by References/In-Reply-To and subject, which any sender controls: a stranger
    /// whose mail Mail folds into a thread, or a reply with someone new on it, is another
    /// conversation, never the thread's history.
    func test_aMailThreadSplitsByAudience() {
        let ayse = AppleMailHistoryReader.conversationID(thread: 77, rowID: 1, people: ["ayse@example.com"])
        XCTAssertEqual(ayse, AppleMailHistoryReader.conversationID(thread: 77, rowID: 9, people: ["AYSE@example.com"]))
        XCTAssertNotEqual(ayse, AppleMailHistoryReader.conversationID(thread: 77, rowID: 2, people: ["mallory@example.org"]))
        XCTAssertNotEqual(ayse, AppleMailHistoryReader.conversationID(thread: 77, rowID: 3,
                                                                      people: ["ayse@example.com", "mallory@example.org"]))
    }

    // MARK: - Outlook

    private func outlookFixture() throws -> OutlookHistoryReader {
        let data = directory.appendingPathComponent("Profiles/Main Profile/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try makeDatabase(data.appendingPathComponent("Outlook.sqlite").path, """
        CREATE TABLE Mail (Record_RecordID INTEGER PRIMARY KEY, Message_NormalizedSubject TEXT, Message_SenderList TEXT,
            Message_SenderAddressList TEXT, Message_ToRecipientAddressList TEXT, Message_CCRecipientAddressList TEXT,
            Message_Preview TEXT, Message_TimeReceived DATETIME, Message_TimeSent DATETIME,
            Message_IsOutgoingMessage BOOLEAN, Conversation_ConversationID INTEGER);
        INSERT INTO Mail VALUES
            (1, 'POC results', 'Dana Miles', 'dana@acme.example', 'sam@acme.example; alan@acme.example', NULL,
             'Numbers are in, the POC passed.', 1746900000, NULL, 0, 7),
            (2, 'RE: POC results', 'Sam Archer', 'Sam@acme.example', 'dana@acme.example', 'alan@acme.example',
             'Great, let us send it to the client.', 1746900100, 1746900090, 1, 7),
            (3, 'Calendar', 'Bot', 'noreply@example.com', 'sam@acme.example', NULL, '', 1746900200, NULL, 0, 8),
            (4, 'Invoice', 'Bob', 'bob@example.org', 'sam@acme.example', NULL, 'The invoice is attached.', 1746900300, NULL, 0, 0),
            (5, 'Invoice', 'Carol', 'carol@example.org', 'sam@acme.example', NULL, 'Your invoice is ready.', 1746900400, NULL, 0, NULL),
            (6, 'RE: POC results', 'Sam Archer', 'sam@acme.example', 'sam@acme.example', NULL,
             'Spoofed: please wire the money.', 1746900500, NULL, 0, 7),
            (7, 'RE: POC results', 'Dana Miles', 'mallory@example.org', 'sam@acme.example', NULL,
             'Dana here, new address, send the numbers.', 1746900600, NULL, 0, 7);
        """)
        return OutlookHistoryReader(profilesRoot: directory.appendingPathComponent("Profiles").path)
    }

    func test_outlookReadsPreviewsAsThreadsAndKnowsWhichMailIsMine() throws {
        let reader = try outlookFixture()
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 10)
        XCTAssertEqual(page.records.map(\.sourceMessageID), ["1", "2", "4", "5", "6", "7"],
                       "a message without a preview carries nothing")
        XCTAssertEqual(OutlookHistoryReader.Cursor(page.nextCursor).legacy, "7")
        // An incoming mail with the user's address and name in From is not the user's: only
        // Outlook's outgoing flag says that. With no one else on it, it joins no conversation.
        let spoofed = page.records[4]
        XCTAssertFalse(spoofed.isFromMe)
        XCTAssertEqual(spoofed.participants, [])
        XCTAssertNotEqual(spoofed.conversationID, page.records[0].conversationID)
        // A stranger using a known person's display name in the same Outlook thread is identified by
        // address and is another conversation: never mapped into the thread's people.
        let stranger = page.records[5]
        XCTAssertEqual(stranger.participants, ["mallory@example.org"])
        XCTAssertNotEqual(stranger.conversationID, page.records[0].conversationID)
        XCTAssertEqual(page.records[2].conversationID, "message-4", "no thread id (0) is never a shared bucket")
        XCTAssertEqual(page.records[3].conversationID, "message-5", "nor is a missing one")
        XCTAssertTrue(page.hasMore, "New Outlook's store is read after the classic database")
        let (received, sent) = (page.records[0], page.records[1])
        XCTAssertEqual(received.conversationID, sent.conversationID)
        XCTAssertEqual(sent.conversationTitle, "POC results", "reply prefixes are dropped so the thread has one title")
        XCTAssertFalse(received.isFromMe)
        XCTAssertTrue(sent.isFromMe)
        XCTAssertEqual(received.sender, "Dana Miles")
        XCTAssertEqual(received.participants, ["alan@acme.example", "dana@acme.example"], "the user's own address is never a participant")
        XCTAssertEqual(try reader.read(after: page.nextCursor, since: nil, limit: 10).records, [], "no New Outlook store in the fixture")
    }

    func test_outlookWithoutALocalDatabaseIsNotFound() {
        let reader = OutlookHistoryReader(profilesRoot: directory.appendingPathComponent("none").path)
        if case .notFound = reader.readiness() {} else { XCTFail("expected notFound") }
    }

    // MARK: - Documents

    func test_documentsBecomeParagraphRecordsAndResumeFromTheNewestFileRead() throws {
        let folder = directory.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let pricing = folder.appendingPathComponent("pricing.md")
        try "The starter plan costs 2,500 EUR per month.\n\nshort\n\nPilots run for six weeks with two teams."
            .write(to: pricing, atomically: true, encoding: .utf8)
        let other = folder.appendingPathComponent("sub/notes.txt")
        try "Second file paragraph that is long enough.".write(to: other, atomically: true, encoding: .utf8)
        try "binary".write(to: folder.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: pricing.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: other.path)

        let reader = DocumentsHistoryReader(folder: folder.path)
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 100)
        XCTAssertEqual(page.records.map(\.text), [
            "The starter plan costs 2,500 EUR per month.", "Pilots run for six weeks with two teams.",
            "Second file paragraph that is long enough.",
        ], "short paragraphs and other file types are skipped")
        XCTAssertEqual(page.records.first?.conversationID, "pricing.md")
        XCTAssertEqual(page.records.last?.conversationID, "sub/notes.txt")
        XCTAssertEqual(page.records.first?.timestamp, Date(timeIntervalSince1970: 1_000), "records keep the file's own date")
        // The cursor follows when files changed or arrived (here: just now), not their content dates.
        XCTAssertGreaterThan(Double(page.nextCursor ?? "") ?? 0, 2_000)
        XCTAssertTrue(try reader.read(after: page.nextCursor, since: nil, limit: 100).records.isEmpty)
    }

    /// A changed note is read whole (so its removed paragraphs leave memory), and the notes still
    /// there are listed (so deleted ones do), but only when every folder could be read.
    func test_documentsReportWholeNotesAndTheNotesStillThere() throws {
        let folder = directory.appendingPathComponent("Notes", isDirectory: true)
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "The starter plan costs 2,500 EUR per month.".write(to: folder.appendingPathComponent("pricing.md"), atomically: true, encoding: .utf8)
        try "Hidden away but still a note of mine.".write(to: locked.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)
        let reader = DocumentsHistoryReader(folder: folder.path)
        let page = try reader.read(after: nil, since: nil, limit: 100)
        XCTAssertEqual(page.completeConversations, ["pricing.md", "locked/x.md"])
        XCTAssertEqual(reader.liveConversationIDs(), ["pricing.md", "locked/x.md"])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertNil(reader.liveConversationIDs(), "a folder that cannot be read is not a folder whose notes were deleted")
        XCTAssertNil(DocumentsHistoryReader(folder: directory.appendingPathComponent("none").path).liveConversationIDs())
    }

    /// A note that arrives with an old modification date (copied or moved in with its date kept)
    /// is still read: the cursor follows when a file changed or arrived, not its content date.
    func test_aNoteArrivingWithAnOldDateIsStillRead() throws {
        let folder = directory.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reader = DocumentsHistoryReader(folder: folder.path)
        try "The first note is long enough to keep.".write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let first = try reader.read(after: nil, since: nil, limit: 100)
        XCTAssertEqual(first.records.count, 1)
        Thread.sleep(forTimeInterval: 1.1)

        let moved = folder.appendingPathComponent("moved.md")
        try "A note moved in with its old date kept.".write(to: moved, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: moved.path)
        let next = try reader.read(after: first.nextCursor, since: nil, limit: 100)
        XCTAssertEqual(next.records.map(\.conversationID), ["moved.md"])
        XCTAssertEqual(next.records.first?.timestamp, Date(timeIntervalSince1970: 1_000), "the record keeps the file's own date")
    }

    /// The `.emlx` map outlives one sync: mail that arrives later is found by rebuilding it, while a
    /// missing file of older mail (not downloaded) does not rebuild it every time.
    func test_theEmlxMapIsRebuiltForNewerMail() {
        let index = EmlxFileIndex()
        var builds = 0
        var files: [Int64: String] = [1: "/1.emlx", 5: "/5.emlx"]
        let build = { () -> [Int64: String] in
            builds += 1
            return files
        }
        XCTAssertEqual(index.files(needing: [5], build: build)[5], "/5.emlx")
        XCTAssertEqual(index.files(needing: [1, 5], build: build).count, 2)
        XCTAssertEqual(index.files(needing: [3], build: build)[3], nil)
        XCTAssertEqual(builds, 1, "older mail without a file reuses the map")
        files[9] = "/9.emlx"
        XCTAssertEqual(index.files(needing: [9], build: build)[9], "/9.emlx", "new mail finds its file")
        XCTAssertEqual(builds, 2)
    }

    // MARK: - Full Disk Access probe

    func test_fullDiskAccessProbeIsTrueForAnOpenableFileAndUnknownWhenNoneExist() throws {
        let readable = directory.appendingPathComponent("probe.db")
        try Data("x".utf8).write(to: readable)
        let missing = directory.appendingPathComponent("missing.db").path
        XCTAssertEqual(MemoryHistorySync.probeFullDiskAccess(paths: [missing, readable.path]), true)
        XCTAssertNil(MemoryHistorySync.probeFullDiskAccess(paths: [missing]))
    }
}
