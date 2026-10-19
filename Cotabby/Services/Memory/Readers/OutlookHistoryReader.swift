import Foundation
import Logging

/// File overview:
/// Reads the mail that Outlook for Mac keeps in its local profile database, for conversation memory.
///
/// Where the mail is: classic ("legacy") Outlook keeps every message it has synced in
/// `~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/<profile>/Data/Outlook.sqlite`
/// (table `Mail`: subject, sender, recipients, thread, times, and a plain-text preview of the body).
/// The message bodies live in a proprietary binary format next to it, so only the preview is used:
/// up to about 250 characters of what the message itself says, which is the part memory needs.
///
/// What it does not cover: New Outlook keeps its mail in `HxStore.hxd`, an undocumented format with
/// no readable message files, and stops updating `Outlook.sqlite`. After switching to New Outlook
/// this reader therefore sees the mail up to the switch. Adding the same account to Apple Mail
/// makes its current mail available through the Apple Mail source instead.
///
/// The group container belongs to another app and is protected by macOS (App Data protection, which
/// Full Disk Access covers). The layout is undocumented, so columns are probed before reading.
///
/// Mapping to memory records, as for Apple Mail: the thread (`Conversation_ConversationID`) with the
/// message's people (`MailAudience`; a message without a thread is its own conversation), titled
/// with the subject without reply prefixes; from me only when Outlook marks the message outgoing,
/// never because its From address or name is the user's; the participants every other address on
/// it (addresses only, never display names or Reply-To); the cursor the message's record id.
///
/// New Outlook: its mail lives in `HxStore.hxd` next to the profile's `Data` folder, an undocumented
/// store read by `HxStoreFile`. It is read after the classic database, as one source. Its records
/// carry no thread id and no recipients, so a conversation is one topic with one sender
/// (`hxConversation`), never a subject alone, and the user's own mail is a conversation of its own.
/// Nothing is marked from me (the store shows no folder, and a From address can be spoofed); the
/// user's own addresses (the classic database's outgoing senders and the accounts in macOS Internet
/// Accounts) are left out of the participants; the body is the message's HTML as text (else its
/// preview). Its part of the cursor is the newest sent time read, re-read with a two-day look-back
/// so edited and late-synced messages are picked up. Each sync after the first reuses what the
/// previous one read of the store wherever its bytes are unchanged (`HxStoreScanCache`).
nonisolated struct OutlookHistoryReader: MemoryHistoryReading {
    let sourceID = "outlook"
    let profilesRoot: String
    /// What the last scan of New Outlook's store read, shared by copies of this reader.
    let scanCache = HxStoreScanCache()

    init(profilesRoot: String = NSHomeDirectory()
        + "/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles") {
        self.profilesRoot = profilesRoot
    }

    /// The profile database to read: "Main Profile" when present (Outlook's default), else the
    /// first profile that has one.
    var databasePath: String? {
        let candidates = ["Main Profile"] + ((try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? []).sorted()
        return candidates.lazy
            .map { "\(profilesRoot)/\($0)/Data/Outlook.sqlite" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// New Outlook's store for the profile, when present.
    var hxStorePath: String? {
        let candidates = ["Main Profile"] + ((try? FileManager.default.contentsOfDirectory(atPath: profilesRoot)) ?? []).sorted()
        return candidates.lazy.map { "\(profilesRoot)/\($0)/HxStore.hxd" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    func readiness() -> MemorySourceReadiness {
        if let hxStorePath {
            let descriptor = open(hxStorePath, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return .ready
            }
            if errno == EPERM || errno == EACCES { return .needsFullDiskAccess }
        }
        guard let path = databasePath else {
            // The container itself exists only when Outlook is installed; inside it, macOS hides
            // nothing from a listing, so a missing database really means no local mail.
            return FileManager.default.fileExists(atPath: profilesRoot) && !FileManager.default.isReadableFile(atPath: profilesRoot)
                ? .needsFullDiskAccess
                : .notFound("No local Outlook mail on this Mac.")
        }
        do {
            let database = try ReadOnlySQLiteDatabase(path: path)
            return try schemaMatches(database) ? .ready
                : .failed("This version of Outlook stores mail differently; memory cannot read it yet.")
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            return error.readiness
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func schemaMatches(_ database: ReadOnlySQLiteDatabase) throws -> Bool {
        try database.hasColumns(
            ["Record_RecordID", "Message_NormalizedSubject", "Message_SenderList", "Message_SenderAddressList",
             "Message_ToRecipientAddressList", "Message_CCRecipientAddressList", "Message_Preview",
             "Message_TimeReceived", "Message_TimeSent", "Message_IsOutgoingMessage", "Conversation_ConversationID"],
            in: "Mail"
        )
    }

    /// Where a sync resumes: the classic database's last record id and New Outlook's newest time.
    struct Cursor: Equatable {
        var legacy: String?
        var newOutlookMilliseconds: Double?

        /// "L<id>|H<ms>"; a bare number is a cursor written before New Outlook was read.
        init(_ text: String?) {
            guard let text, !text.isEmpty else { return }
            guard text.contains("|") || text.hasPrefix("L") || text.hasPrefix("H") else {
                legacy = text
                return
            }
            for part in text.split(separator: "|") {
                if part.hasPrefix("L") { legacy = String(part.dropFirst()).nilIfEmpty }
                if part.hasPrefix("H") { newOutlookMilliseconds = Double(part.dropFirst()) }
            }
        }

        init(legacy: String?, newOutlookMilliseconds: Double?) {
            self.legacy = legacy
            self.newOutlookMilliseconds = newOutlookMilliseconds
        }

        var text: String {
            "L\(legacy ?? "")|H\(newOutlookMilliseconds.map { String(format: "%.0f", $0) } ?? "")"
        }
    }

    static let newOutlookLookback: TimeInterval = 2 * 86_400

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        var position = Cursor(cursor)
        if databasePath != nil {
            let page = try readLegacy(after: position.legacy, since: since, limit: limit)
            if !page.records.isEmpty || page.hasMore {
                position.legacy = page.nextCursor ?? position.legacy
                // More to come: New Outlook's store follows the classic database.
                return MemoryReadPage(records: page.records, nextCursor: position.text, hasMore: true)
            }
        }
        guard let hxStorePath else {
            return MemoryReadPage(records: [], nextCursor: nil, hasMore: false)
        }
        let previous = position.newOutlookMilliseconds ?? 0
        let after = Date(timeIntervalSince1970: max(0, previous / 1000 - Self.newOutlookLookback))
        let own = ownAddresses()
        var newest = previous
        var records: [MemoryIngestRecord] = []
        let started = Date()
        let (messages, report) = try HxStoreFile.scan(at: URL(fileURLWithPath: hxStorePath), sentAfter: after, cache: scanCache)
        CotabbyLogger.app.info("Outlook store scanned", metadata: [
            "megabytes": .stringConvertible(report.bytes >> 20),
            "records": .stringConvertible(report.records),
            "reused_records": .stringConvertible(report.reusedRecords),
            "reused_percent": .stringConvertible(report.bytes > 0 ? 100 * report.reusedBytes / report.bytes : 0),
            "segments": .stringConvertible(report.segments),
            "messages": .stringConvertible(report.messages),
            "seconds": .string(String(format: "%.1f", Date().timeIntervalSince(started)))
        ])
        for message in messages {
            guard let sent = message.sent, sent > after, sent >= (since ?? .distantPast) else { continue }
            newest = max(newest, sent.timeIntervalSince1970 * 1000)
            guard let record = Self.ingestRecord(message, sent: sent, ownAddresses: own) else { continue }
            records.append(record)
        }
        position.newOutlookMilliseconds = newest
        return MemoryReadPage(records: records, nextCursor: newest > previous ? position.text : nil, hasMore: false)
    }

    static func ingestRecord(_ message: HxMailRecord, sent: Date, ownAddresses: Set<String>) -> MemoryIngestRecord? {
        let body = (message.bodyText ?? message.bodyHTML.map(EmailBodyExtractor.htmlToText)).flatMap { $0.isEmpty ? nil : $0 }
        guard var text = body ?? message.preview, !text.isEmpty else { return nil }
        // An invitation's body ends in the join-a-call block (links, dial-in, passcode): keep the agenda.
        if message.messageClass.hasPrefix("IPM.Schedule") { text = CalendarEventText.cleanedNotes(text) }
        guard !text.isEmpty else { return nil }
        let sender = message.senderAddress ?? ""
        // Never marked as the user's: the store does not show which folder a message is in, and a
        // From address can be spoofed, so a mail "from" the user could put words in their mouth when a
        // prompt attributes it to "You". The user's address is still left out of the participants.
        let isOwnAddress = ownAddresses.contains(sender)
        let topic = message.topic.flatMap { $0.isEmpty ? nil : $0 }
        let conversation = hxConversation(messageID: message.messageID, topic: topic, sender: sender, isOwnAddress: isOwnAddress)
        return MemoryIngestRecord(
            // The sender is part of the identity (see `HxStoreFile`): a record from someone else
            // that reads the same id is another message, never a replacement for this one.
            sourceMessageID: "hx:" + message.messageID + "|" + sender,
            conversationID: conversation.id,
            conversationTitle: conversation.title,
            sender: message.senderName ?? sender,
            isFromMe: false,
            timestamp: sent,
            text: text,
            participants: isOwnAddress || sender.isEmpty ? [] : [sender],
            subject: message.subject ?? topic ?? ""
        )
    }

    /// The conversation a New Outlook message belongs to. HxStore records carry no thread id and no
    /// recipients, only the sender, so a subject alone must never make a thread: two threads that
    /// share "Invoice", or the same subject from two people, would merge their audiences. A
    /// conversation is one topic with one other person. A message with no sender, or the user's own
    /// (whose recipients are unknown), is a conversation of its own with no title: no window title
    /// can select it, and with no participants it never widens into another conversation.
    static func hxConversation(messageID: String, topic: String?, sender: String, isOwnAddress: Bool)
        -> (id: String, title: String) {
        guard let topic, !sender.isEmpty, !isOwnAddress else { return ("hx:" + messageID + "|" + sender, "") }
        return ("hx-topic:" + topic.lowercased() + "|" + sender, topic)
    }

    /// The user's own addresses: the classic database's outgoing senders and the mail accounts in
    /// macOS Internet Accounts.
    func ownAddresses() -> Set<String> {
        var own = Set<String>()
        if let path = databasePath, let database = try? ReadOnlySQLiteDatabase(path: path) {
            own.formUnion((try? Self.ownAddresses(database)) ?? [])
        }
        let accounts = NSHomeDirectory() + "/Library/Accounts/Accounts4.sqlite"
        if let database = try? ReadOnlySQLiteDatabase(path: accounts),
           let rows = try? database.rows("SELECT DISTINCT lower(ZUSERNAME) AS name FROM ZACCOUNT WHERE ZUSERNAME LIKE '%@%'") {
            own.formUnion(rows.compactMap { $0["name"]?.string })
        }
        return own
    }

    private func readLegacy(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        guard let path = databasePath else { throw ReadOnlySQLiteDatabase.DatabaseError.missing(profilesRoot) }
        let database = try ReadOnlySQLiteDatabase(path: path)
        guard try schemaMatches(database) else {
            throw ReadOnlySQLiteDatabase.DatabaseError.sqlite("Unrecognized Outlook database layout.")
        }
        let after = Int64(cursor ?? "") ?? 0
        let rows = try database.rows(
            """
            SELECT Record_RecordID AS id, Conversation_ConversationID AS thread,
                   COALESCE(Message_TimeReceived, Message_TimeSent) AS received,
                   Message_NormalizedSubject AS subject, Message_SenderList AS sender_name,
                   Message_SenderAddressList AS sender, Message_ToRecipientAddressList AS recipients_to,
                   Message_CCRecipientAddressList AS recipients_cc, Message_Preview AS preview,
                   Message_IsOutgoingMessage AS outgoing
            FROM Mail
            WHERE Record_RecordID > ? AND COALESCE(Message_TimeReceived, Message_TimeSent, 0) >= ?
            ORDER BY Record_RecordID LIMIT ?
            """,
            [.integer(after), .real(since?.timeIntervalSince1970 ?? 0), .integer(Int64(limit))]
        )
        guard !rows.isEmpty else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }

        let ownAddresses = try Self.ownAddresses(database)
        var records: [MemoryIngestRecord] = []
        for row in rows {
            guard let id = row["id"]?.int else { continue }
            let text = (row["preview"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let senderAddress = Self.addresses(row["sender"]?.string).first ?? ""
            // Outlook's own outgoing flag, not the From address: anyone can put the user's address there.
            let isFromMe = (row["outgoing"]?.int ?? 0) != 0
            let everyone = [senderAddress] + Self.addresses(row["recipients_to"]?.string) + Self.addresses(row["recipients_cc"]?.string)
            let subject = AppleMailHistoryReader.baseSubject(row["subject"]?.string ?? "")
            // Addresses only, never display names or Reply-To: a name is the sender's to choose.
            let people = Set(everyone.filter { !$0.isEmpty && !ownAddresses.contains($0) })
            let senderName = (row["sender_name"]?.string ?? "").split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            records.append(MemoryIngestRecord(
                sourceMessageID: String(id),
                // Outlook's own thread id with the message's people (as for Apple Mail: a thread joined
                // by headers a sender controls splits by audience); a missing or zero id is never a
                // shared bucket.
                conversationID: row["thread"]?.int
                    .flatMap { $0 > 0 ? MailAudience.conversationID(thread: "thread-\($0)", people: people) : nil }
                    ?? "message-\(id)",
                conversationTitle: subject,
                sender: senderName.isEmpty ? senderAddress : senderName,
                isFromMe: isFromMe,
                timestamp: Date(timeIntervalSince1970: row["received"]?.double ?? 0),
                text: text,
                participants: people.sorted(),
                subject: subject
            ))
        }
        let last = rows.last?["id"]?.int
        return MemoryReadPage(records: records, nextCursor: last.map(String.init), hasMore: rows.count == limit)
    }

    /// The user's own addresses: senders of the messages Outlook marks as outgoing.
    static func ownAddresses(_ database: ReadOnlySQLiteDatabase) throws -> Set<String> {
        let rows = try database.rows(
            "SELECT DISTINCT Message_SenderAddressList AS sender FROM Mail WHERE Message_IsOutgoingMessage = 1"
        )
        return Set(rows.flatMap { addresses($0["sender"]?.string) })
    }

    /// Outlook stores address lists as "a@example.com; b@example.org".
    static func addresses(_ list: String?) -> [String] {
        (list ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
