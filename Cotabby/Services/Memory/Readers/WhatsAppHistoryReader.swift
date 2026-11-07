import Foundation

/// File overview:
/// Reads WhatsApp for Mac's message history for conversation memory.
///
/// WhatsApp keeps its history in an unencrypted Core Data SQLite store in its group container,
/// protected by macOS (App Data protection / Full Disk Access). Its layout is undocumented, so the
/// reader probes for the columns it uses before reading and reports a clear failure if an update
/// changed them, rather than misreading.
///
/// Mapping to memory records:
/// - Conversation: the chat session's JID (`…@s.whatsapp.net` for a person, `…@g.us` for a
///   group), titled with the partner or group name, which is what WhatsApp's chat header shows.
///   Suggestions match it against the focused window's title (`FocusedInputContext.windowTitle`);
///   WhatsApp titles its window "WhatsApp", so reading the open chat's name is a follow-up.
/// - Participants: JIDs, not names, so memory's audience rule (only conversations with exactly the
///   same people) identifies a person reliably; names are not unique and can change.
/// - Only messages with text (including captions and links), from 1:1 chats and groups; status
///   updates, broadcasts and system notices are skipped. System notices are message types 6 (group
///   events: joins, subject changes) and 10 (calls, security-code changes), whose "text" is ids such
///   as `…@lid`. `ZGROUPEVENTTYPE` is no filter: WhatsApp sets it to 2 on ordinary messages, so
///   skipping nonzero values (as an earlier reading did) dropped nearly every message.
/// - Cursor: `r<reading>|<store id>:<row>`: which reading wrote it (`Cursor.currentReading`, raised
///   whenever the messages read change, so rows passed under an older reading are read again), the
///   Core Data store's identity (`Z_METADATA.Z_UUID`) and the last message's primary key. Rows only grow within one store, but linking WhatsApp again (after a
///   logout or reset) or reinstalling it creates a new store whose rows count from 1: a bare row
///   cursor would skip every new message until the new rows passed it. A cursor of another store,
///   one without a store (saved by an earlier build), or one past the store's last row therefore
///   reads the store from the start, as does a cursor of an earlier reading. That re-read is safe: records are keyed by WhatsApp's own
///   message id (`ZSTANZAID`), which a re-linked store keeps, so memory matches what it holds.
nonisolated struct WhatsAppHistoryReader: MemoryHistoryReading {
    let sourceID = "whatsapp"
    /// Added to every group's participants, so a group never shares memory with a 1:1 chat.
    static let groupMarker = "whatsapp-group:"
    let databasePath: String

    init(databasePath: String = WhatsAppHistoryReader.defaultDatabasePath) {
        self.databasePath = databasePath
    }

    static var defaultDatabasePath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }

    /// Core Data stores dates as seconds since 2001-01-01.
    static let appleEpochOffset: TimeInterval = 978_307_200

    func readiness() -> MemorySourceReadiness {
        do {
            let database = try ReadOnlySQLiteDatabase(path: databasePath)
            return try schemaMatches(database) ? .ready
                : .failed("This WhatsApp version stores messages differently; memory cannot read it yet.")
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            return readiness(for: error)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A logged-out or reset WhatsApp keeps its group container but has no chat store until it is
    /// linked again; a container that is missing too means WhatsApp was never set up here.
    func readiness(for error: ReadOnlySQLiteDatabase.DatabaseError) -> MemorySourceReadiness {
        guard case .missing = error,
              FileManager.default.fileExists(atPath: (databasePath as NSString).deletingLastPathComponent) else {
            return error.readiness
        }
        return .notFound("WhatsApp is not linked on this Mac, so it has no chat history yet. Link it in WhatsApp "
            + "with your phone; memory reads it on its next sync and keeps what it already holds.")
    }

    /// `r<reading>|<store id>:<row>` (the store id empty for a store without an identity). Cursors
    /// saved by earlier builds, a bare row or `<store id>:<row>`, read as reading 1.
    struct Cursor: Equatable {
        /// Raised whenever the set of messages read changes: 2 stopped skipping every message with a
        /// nonzero `ZGROUPEVENTTYPE`.
        static let currentReading = 2

        let reading: Int
        let store: String?
        let row: Int64

        init(reading: Int = Cursor.currentReading, store: String?, row: Int64) {
            self.reading = reading
            self.store = store
            self.row = row
        }

        init?(_ text: String?) {
            guard let text, !text.isEmpty else { return nil }
            var reading = 1
            var position = Substring(text)
            if text.hasPrefix("r"), let bar = text.firstIndex(of: "|"),
               let version = Int(text[text.index(after: text.startIndex)..<bar]) {
                reading = version
                position = text[text.index(after: bar)...]
            }
            // Split at the last colon: the row never has one, a store id might.
            if let colon = position.lastIndex(of: ":") {
                guard let row = Int64(position[position.index(after: colon)...]) else { return nil }
                let store = String(position[..<colon])
                self.init(reading: reading, store: store.isEmpty ? nil : store, row: row)
            } else {
                guard let row = Int64(position) else { return nil }
                self.init(reading: reading, store: nil, row: row)
            }
        }

        var text: String { "r\(reading)|\(store ?? ""):\(row)" }
    }

    /// The row to read after: the cursor's, when this reading wrote it for this store; 0 (the whole
    /// store) when an earlier reading wrote it, it came from another store, names none while the
    /// store has one, or points past the store's last row (a replaced store without an identity).
    static func startRow(after cursor: Cursor?, store: String?, lastRow: Int64) -> Int64 {
        guard let cursor else { return 0 }
        if cursor.reading != Cursor.currentReading || cursor.store != store || cursor.row > lastRow { return 0 }
        return cursor.row
    }

    /// The Core Data store's identity: new each time WhatsApp creates its store, the same for as
    /// long as that store lives. Nil when the store has no metadata table.
    private func storeIdentity(_ database: ReadOnlySQLiteDatabase) throws -> String? {
        guard try database.hasColumns(["Z_UUID"], in: "Z_METADATA") else { return nil }
        return try database.rows("SELECT Z_UUID AS id FROM Z_METADATA LIMIT 1").first?["id"]?.string
    }

    private func schemaMatches(_ database: ReadOnlySQLiteDatabase) throws -> Bool {
        try database.hasColumns(
            ["Z_PK", "ZTEXT", "ZISFROMME", "ZMESSAGEDATE", "ZCHATSESSION", "ZGROUPMEMBER", "ZSTANZAID",
             "ZPUSHNAME", "ZMESSAGETYPE"],
            in: "ZWAMESSAGE"
        ) && database.hasColumns(["Z_PK", "ZCONTACTJID", "ZPARTNERNAME", "ZSESSIONTYPE"], in: "ZWACHATSESSION")
            && database.hasColumns(["Z_PK", "ZCHATSESSION", "ZMEMBERJID", "ZCONTACTNAME", "ZFIRSTNAME"], in: "ZWAGROUPMEMBER")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let database = try ReadOnlySQLiteDatabase(path: databasePath)
        guard try schemaMatches(database) else {
            throw ReadOnlySQLiteDatabase.DatabaseError.sqlite("Unrecognized WhatsApp database layout.")
        }
        let store = try storeIdentity(database)
        let lastRow = try database.rows("SELECT COALESCE(MAX(Z_PK), 0) AS last FROM ZWAMESSAGE").first?["last"]?.int ?? 0
        let saved = Cursor(cursor)
        let after = Self.startRow(after: saved, store: store, lastRow: lastRow)
        let sinceApple = (since?.timeIntervalSince1970).map { $0 - Self.appleEpochOffset } ?? -Double.greatestFiniteMagnitude
        // ZSESSIONTYPE: 0 = one-to-one, 1 = group (others are broadcast lists and status).
        // ZMESSAGETYPE 6 and 10 are system notices (see the file overview).
        let rows = try database.rows(
            """
            SELECT m.Z_PK AS pk, m.ZSTANZAID AS stanza, m.ZTEXT AS text, m.ZISFROMME AS from_me,
                   m.ZMESSAGEDATE AS date, m.ZPUSHNAME AS push_name,
                   s.Z_PK AS session, s.ZCONTACTJID AS jid, s.ZPARTNERNAME AS title, s.ZSESSIONTYPE AS session_type,
                   g.ZCONTACTNAME AS member_name, g.ZFIRSTNAME AS member_first_name, g.ZMEMBERJID AS member_jid
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            WHERE m.Z_PK > ? AND m.ZTEXT IS NOT NULL AND m.ZTEXT != ''
              AND s.ZSESSIONTYPE IN (0, 1) AND COALESCE(m.ZMESSAGETYPE, 0) NOT IN (6, 10)
              AND COALESCE(m.ZMESSAGEDATE, 0) >= ?
            ORDER BY m.Z_PK LIMIT ?
            """,
            [.integer(after), .real(sinceApple), .integer(Int64(limit))]
        )
        var membersBySession: [Int64: [String]] = [:]
        // A group's member list does not say who was there when: a group can never vouch for what
        // any one member saw, so every group carries its own marker and never has exactly the
        // people of a 1:1 chat or of another group (the store's "same people" rule).
        func members(of session: Int64, chatJID: String, isGroup: Bool) throws -> [String] {
            guard isGroup else { return [chatJID] }
            if let cached = membersBySession[session] { return cached }
            let jids = try database.rows(
                "SELECT ZMEMBERJID AS jid FROM ZWAGROUPMEMBER WHERE ZCHATSESSION = ? AND ZMEMBERJID IS NOT NULL",
                [.integer(session)]
            ).compactMap { $0["jid"]?.string } + [Self.groupMarker + chatJID]
            membersBySession[session] = jids
            return jids
        }

        var records: [MemoryIngestRecord] = []
        for row in rows {
            guard let pk = row["pk"]?.int, let text = row["text"]?.string, let jid = row["jid"]?.string,
                  let session = row["session"]?.int else { continue }
            let isGroup = row["session_type"]?.int == 1
            let isFromMe = row["from_me"]?.int == 1
            let title = row["title"]?.string ?? jid
            let sender: String
            if isFromMe {
                sender = "You"
            } else if isGroup {
                sender = row["member_name"]?.string ?? row["member_first_name"]?.string
                    ?? row["push_name"]?.string ?? row["member_jid"]?.string ?? "Someone"
            } else {
                sender = title
            }
            let appleDate = row["date"]?.double ?? 0
            records.append(MemoryIngestRecord(
                sourceMessageID: row["stanza"]?.string ?? String(pk),
                conversationID: jid,
                conversationTitle: title,
                sender: sender,
                isFromMe: isFromMe,
                timestamp: Date(timeIntervalSince1970: appleDate + Self.appleEpochOffset),
                // Capped like mail bodies: memory needs the gist, and one enormous message must not
                // cost a whole sync's time to scrub, store and embed.
                text: text.count > EmailBodyExtractor.maximumCharacters
                    ? String(text.prefix(EmailBodyExtractor.maximumCharacters)) : text,
                participants: try members(of: session, chatJID: jid, isGroup: isGroup),
                subject: nil
            ))
        }
        // A cursor that starts this store over is replaced even when the store has no messages yet,
        // so its first rows are read as they arrive instead of waiting behind the old store's row.
        let startedOver = saved != nil && after == 0
        let last = rows.last?["pk"]?.int ?? (startedOver ? 0 : nil)
        return MemoryReadPage(records: records, nextCursor: last.map { Cursor(store: store, row: $0).text },
                              hasMore: rows.count == limit)
    }
}
