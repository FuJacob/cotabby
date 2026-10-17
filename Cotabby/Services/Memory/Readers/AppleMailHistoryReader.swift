import Foundation

/// File overview:
/// Reads the Mail app's local mail for conversation memory.
///
/// Mail keeps an index of every message in `~/Library/Mail/V10/MailData/Envelope Index` (SQLite:
/// subjects, senders, recipients, mailboxes, thread ids, and for messages Mail has rendered, a
/// plain-text summary of the body) and each message itself as an `.emlx` file. Both are protected
/// by Full Disk Access. The layout is undocumented, so columns are probed before reading.
///
/// Mapping to memory records:
/// - Conversation: Mail's own thread (`conversation_id`) with the message's people, titled with the
///   thread's subject without its "Re:"/"Fwd:" prefix (what the Playground lists; suggestions do
///   not look mail threads up by subject, see `ConversationScopeResolver`). Mail joins a thread by
///   References/In-Reply-To headers and subjects, which any sender controls, so a thread id alone
///   could fold an outsider's mail (and later replies to them) into a thread they never saw; each
///   audience within a thread is therefore its own conversation (`conversationID`).
/// - From me: the message is filed in a Sent mailbox or carries a Sent label (Gmail). The From
///   address alone is not enough: anyone can write the user's address there, and a spoofed mail
///   marked as the user's own would put words in the user's mouth when a prompt attributes it to "You".
///   Another copy of a sent message (the inbox copy of mail sent to a list the user is on) is
///   skipped as a duplicate rather than trusted by its Message-ID, which a sender can reuse.
/// - Mailbox roles come from the mailbox path, never the account or host part of the URL, where a
///   name could contain "sent". Sent must be the mailbox's exact name (mistaking a folder for Sent
///   would make its mail the user's); junk is any folder on the path with a junk word in its name
///   (reading less is the safe mistake there).
/// - Participants: every other address on the message (sender and recipients), lowercased; the
///   user's own addresses are the senders of Sent mail.
/// - Junk and spam mailboxes are skipped.
/// - Body: Mail's stored summary when present, else the `.emlx` file parsed by
///   `EmailBodyExtractor`. Quoted history is stripped by the engine.
/// - Cursor: the message's ROWID, which only grows.
nonisolated struct AppleMailHistoryReader: MemoryHistoryReading {
    let sourceID = "apple_mail"
    let mailRoot: String
    /// The ROWID -> `.emlx` map, built once and reused across pages and syncs (walking a large mail
    /// folder takes seconds), rebuilt when mail newer than the map needs its file.
    private let fileIndex = EmlxFileIndex()

    init(mailRoot: String = NSHomeDirectory() + "/Library/Mail/V10") {
        self.mailRoot = mailRoot
    }

    var envelopeIndexPath: String { mailRoot + "/MailData/Envelope Index" }

    func readiness() -> MemorySourceReadiness {
        do {
            let database = try ReadOnlySQLiteDatabase(path: envelopeIndexPath)
            return try schemaMatches(database) ? .ready
                : .failed("This version of Mail stores messages differently; memory cannot read it yet.")
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            return error.readiness
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func schemaMatches(_ database: ReadOnlySQLiteDatabase) throws -> Bool {
        try database.hasColumns(
            ["ROWID", "sender", "subject", "summary", "date_received", "mailbox", "deleted", "conversation_id"],
            in: "messages"
        ) && database.hasColumns(["ROWID", "subject"], in: "subjects")
            && database.hasColumns(["ROWID", "address", "comment"], in: "addresses")
            && database.hasColumns(["message", "address", "type"], in: "recipients")
            && database.hasColumns(["ROWID", "url"], in: "mailboxes")
            && database.hasColumns(["ROWID", "summary"], in: "summaries")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let database = try ReadOnlySQLiteDatabase(path: envelopeIndexPath)
        guard try schemaMatches(database) else {
            throw ReadOnlySQLiteDatabase.DatabaseError.sqlite("Unrecognized Mail database layout.")
        }
        let after = Int64(cursor ?? "") ?? 0
        let sinceSeconds = since?.timeIntervalSince1970 ?? 0
        let roles = try Self.mailboxRoles(database)
        let sent = roles.sent.map(String.init).joined(separator: ",")
        let junk = roles.junk.map(String.init).joined(separator: ",")
        let rows = try database.rows(
            """
            SELECT m.ROWID AS rowid, m.conversation_id AS thread, m.date_received AS received,
                   s.subject AS subject, a.address AS sender, a.comment AS sender_name, sm.summary AS summary,
                   \(try Self.sentExpression(database, sent: sent)) AS sent
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN summaries sm ON sm.ROWID = m.summary
            WHERE m.ROWID > ? AND m.deleted = 0 AND m.date_received >= ? AND m.mailbox NOT IN (\(junk))
              AND NOT \(try Self.copyOfSentExpression(database, sent: sent))
            ORDER BY m.ROWID LIMIT ?
            """,
            [.integer(after), .real(sinceSeconds), .integer(Int64(limit))]
        )
        guard !rows.isEmpty else { return MemoryReadPage(records: [], nextCursor: nil, hasMore: false) }

        let ownAddresses = try Self.ownAddresses(database, sent: sent)
        let recipients = try Self.recipients(of: rows.compactMap { $0["rowid"]?.int }, database: database)
        let needed = rows.filter { ($0["summary"]?.string?.count ?? 0) < 40 }.compactMap { $0["rowid"]?.int }
        let files = needed.isEmpty ? [:] : fileIndex.files(needing: needed, build: emlxFiles)

        var records: [MemoryIngestRecord] = []
        for row in rows {
            guard let rowid = row["rowid"]?.int else { continue }
            let senderAddress = (row["sender"]?.string ?? "").lowercased()
            let summary = row["summary"]?.string ?? ""
            let body: String?
            if summary.count >= 40 {
                body = summary
            } else if let path = files[rowid], Self.fileSize(path) <= EmailBodyExtractor.maximumMessageBytes,
                      let data = FileManager.default.contents(atPath: path) {
                body = EmailBodyExtractor.bodyFromEmlx(data)
            } else {
                body = nil
            }
            guard let text = body, !text.isEmpty else { continue }
            let subject = Self.baseSubject(row["subject"]?.string ?? "")
            let others = Set(([senderAddress] + (recipients[rowid] ?? [])).filter { !$0.isEmpty && !ownAddresses.contains($0) })
            let thread = Self.conversationID(thread: row["thread"]?.int, rowID: rowid, people: others)
            records.append(MemoryIngestRecord(
                sourceMessageID: String(rowid),
                conversationID: thread,
                conversationTitle: subject,
                sender: Self.displayName(address: senderAddress, comment: row["sender_name"]?.string),
                isFromMe: row["sent"]?.int == 1,
                timestamp: Date(timeIntervalSince1970: row["received"]?.double ?? 0),
                text: text,
                participants: others.sorted(),
                subject: subject
            ))
        }
        let last = rows.last?["rowid"]?.int
        return MemoryReadPage(records: records, nextCursor: last.map(String.init), hasMore: rows.count == limit)
    }

    // MARK: - Helpers

    /// The user's own addresses: senders of messages filed in Sent mailboxes. Used to leave the
    /// user out of participant lists, never to decide who wrote a message.
    static func ownAddresses(_ database: ReadOnlySQLiteDatabase, sent: String) throws -> Set<String> {
        let rows = try database.rows(
            """
            SELECT DISTINCT lower(a.address) AS address FROM messages m
            JOIN addresses a ON a.ROWID = m.sender
            WHERE m.mailbox IN (\(sent))
            """
        )
        return Set(rows.compactMap { $0["address"]?.string })
    }

    enum MailboxRole: Equatable {
        case sent
        case junk
        case other
    }

    /// Mail's own thread id plus the message's people (everyone but the user). A missing or zero id
    /// (no thread) gives the message a conversation of its own, never a bucket shared with every
    /// other unthreaded message. The people are part of the id because Mail threads by headers a
    /// sender controls: a stranger who joins a thread, or a reply with someone new on it, becomes
    /// another conversation instead of gaining the thread's history.
    static func conversationID(thread: Int64?, rowID: Int64, people: Set<String>) -> String {
        guard let thread, thread > 0 else { return "message-\(rowID)" }
        return MailAudience.conversationID(thread: String(thread), people: people)
    }

    /// Sent and junk folder names across providers and the user's languages, compared without case
    /// or accents ("Gönderilmiş Öğeler" matches "gonderilmis ogeler").
    static let sentNames: Set<String> = [
        "sent", "sent messages", "sent mail", "sent items", "gonderilmis ogeler", "gonderilmis postalar",
        "gonderilenler", "gonderilen", "gesendet", "gesendete elemente", "gesendete objekte", "elements envoyes",
        "envoyes", "messages envoyes", "enviados", "elementos enviados", "itens enviados", "posta inviata",
        "verzonden items", "verzonden"
    ]
    static let junkWords = ["junk", "spam", "bulk", "gereksiz", "istenmeyen", "indesirable", "no deseado"]

    /// The role of a mailbox from the folders on its URL's path (percent-decoded), after the scheme
    /// and the account or host (`imap://ACCOUNT/Folder/Sub`).
    static func role(ofMailboxURL url: String) -> MailboxRole {
        // URLComponents separates the host from the path, including an empty host (`local:///Sent`).
        let path = URLComponents(string: url)?.percentEncodedPath ?? url
        let folders = path.split(separator: "/").map { part -> String in
            (String(part).removingPercentEncoding ?? String(part))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "ı", with: "i")
                .trimmingCharacters(in: .whitespaces)
        }
        if folders.contains(where: { folder in junkWords.contains { folder.contains($0) } }) { return .junk }
        if let name = folders.last, sentNames.contains(name) { return .sent }
        return .other
    }

    /// The ROWIDs of the Sent and junk mailboxes.
    static func mailboxRoles(_ database: ReadOnlySQLiteDatabase) throws -> (sent: [Int64], junk: [Int64]) {
        var sent: [Int64] = [], junk: [Int64] = []
        for row in try database.rows("SELECT ROWID AS id, url FROM mailboxes") {
            guard let id = row["id"]?.int, let url = row["url"]?.string else { continue }
            switch role(ofMailboxURL: url) {
            case .sent: sent.append(id)
            case .junk: junk.append(id)
            case .other: break
            }
        }
        return (sent, junk)
    }

    /// SQL that is 1 when the message `m` was sent by the user: filed in a Sent mailbox, or (Gmail,
    /// when this version of Mail has labels) labelled with one.
    static func sentExpression(_ database: ReadOnlySQLiteDatabase, sent: String) throws -> String {
        var checks = ["m.mailbox IN (\(sent))"]
        if try database.hasColumns(["message_id", "mailbox_id"], in: "labels") {
            checks.append("EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(sent)))")
        }
        return "(" + checks.joined(separator: " OR ") + ")"
    }

    /// SQL that is 1 when `m` is another copy of a message in a Sent mailbox (same Message-ID). Such
    /// a copy is skipped: a genuine one duplicates the Sent copy, and a forged one reusing the id
    /// must not be read at all.
    static func copyOfSentExpression(_ database: ReadOnlySQLiteDatabase, sent: String) throws -> String {
        guard try database.hasColumns(["message_id"], in: "messages") else { return "0" }
        return """
            (m.mailbox NOT IN (\(sent)) AND m.message_id <> 0 AND EXISTS (SELECT 1 FROM messages t \
            WHERE t.message_id = m.message_id AND t.deleted = 0 AND t.mailbox IN (\(sent))))
            """
    }

    static func recipients(of messages: [Int64], database: ReadOnlySQLiteDatabase) throws -> [Int64: [String]] {
        guard let first = messages.min(), let last = messages.max() else { return [:] }
        let rows = try database.rows(
            """
            SELECT r.message AS message, lower(a.address) AS address FROM recipients r
            JOIN addresses a ON a.ROWID = r.address WHERE r.message BETWEEN ? AND ?
            """,
            [.integer(first), .integer(last)]
        )
        var result: [Int64: [String]] = [:]
        for row in rows {
            guard let message = row["message"]?.int, let address = row["address"]?.string else { continue }
            result[message, default: []].append(address)
        }
        return result
    }

    /// Maps message ROWIDs to their `.emlx` files. Mail names each file `<ROWID>.emlx` (or
    /// `<ROWID>.partial.emlx` when attachments are stored separately) somewhere under the account's
    /// mailbox folders.
    func emlxFiles() -> [Int64: String] {
        var files: [Int64: String] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: mailRoot) else { return files }
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".emlx") else { continue }
            let name = (relative as NSString).lastPathComponent
            guard let rowid = Int64(name.split(separator: ".").first ?? "") else { continue }
            // Prefer a full message over a partial one when both exist.
            if files[rowid] == nil || !name.contains("partial") {
                files[rowid] = mailRoot + "/" + relative
            }
        }
        return files
    }

    /// A subject without its reply and forward prefixes, so every message of a thread (and the
    /// compose window's title) agree on one title.
    static func baseSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        let prefix = try? NSRegularExpression(
            pattern: "^(re|fw|fwd|aw|wg|sv|ynt|ilt|tr)\\s*(\\[\\d+\\])?\\s*:\\s*", options: .caseInsensitive
        )
        while let prefix, let match = prefix.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range, in: result) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? .max
    }

    static func displayName(address: String, comment: String?) -> String {
        let name = comment?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? ""
        return name.isEmpty ? address : name
    }
}

/// Caches the `.emlx` file map for one reader. A class (with a lock) so the reader struct can stay
/// a Sendable value while the map is built lazily on first need.
///
/// The reader lives as long as the app, so the map is rebuilt when a page needs the file of mail
/// newer than anything in it (it arrived after the map was built); otherwise that mail's body
/// would be missing and the cursor would move past it for good. A needed message older than the
/// map's newest simply has no file (Mail has not downloaded it), and does not trigger a rebuild.
nonisolated final class EmlxFileIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [Int64: String]?
    private var newest: Int64 = .min

    func files(needing rowIDs: [Int64], build: () -> [Int64: String]) -> [Int64: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached, !rowIDs.contains(where: { cached[$0] == nil && $0 > newest }) { return cached }
        let built = build()
        cached = built
        newest = built.keys.max() ?? .min
        return built
    }
}
