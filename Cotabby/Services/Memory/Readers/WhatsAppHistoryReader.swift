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
/// - Only messages with text (including captions), from 1:1 chats and groups; status updates,
///   broadcasts and group system events are skipped.
/// - Cursor: the message's Core Data primary key, which only grows.
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
            return error.readiness
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func schemaMatches(_ database: ReadOnlySQLiteDatabase) throws -> Bool {
        try database.hasColumns(
            ["Z_PK", "ZTEXT", "ZISFROMME", "ZMESSAGEDATE", "ZCHATSESSION", "ZGROUPMEMBER", "ZSTANZAID",
             "ZPUSHNAME", "ZGROUPEVENTTYPE"],
            in: "ZWAMESSAGE"
        ) && database.hasColumns(["Z_PK", "ZCONTACTJID", "ZPARTNERNAME", "ZSESSIONTYPE"], in: "ZWACHATSESSION")
            && database.hasColumns(["Z_PK", "ZCHATSESSION", "ZMEMBERJID", "ZCONTACTNAME", "ZFIRSTNAME"], in: "ZWAGROUPMEMBER")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        let database = try ReadOnlySQLiteDatabase(path: databasePath)
        guard try schemaMatches(database) else {
            throw ReadOnlySQLiteDatabase.DatabaseError.sqlite("Unrecognized WhatsApp database layout.")
        }
        let after = Int64(cursor ?? "") ?? 0
        let sinceApple = (since?.timeIntervalSince1970).map { $0 - Self.appleEpochOffset } ?? -Double.greatestFiniteMagnitude
        // ZSESSIONTYPE: 0 = one-to-one, 1 = group (others are broadcast lists and status).
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
              AND s.ZSESSIONTYPE IN (0, 1) AND COALESCE(m.ZGROUPEVENTTYPE, 0) = 0
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
        let last = rows.last?["pk"]?.int
        return MemoryReadPage(records: records, nextCursor: last.map(String.init), hasMore: rows.count == limit)
    }
}
