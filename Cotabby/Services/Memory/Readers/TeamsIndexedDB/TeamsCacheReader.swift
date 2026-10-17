import Foundation
import Logging

/// File overview:
/// Reads the chats the new Microsoft Teams client keeps in its local cache, for conversation memory.
///
/// Where the messages are: new Teams (`com.microsoft.teams2`) is a web app in a WebView, and keeps
/// what it has shown in Chromium IndexedDB under its sandbox container:
/// `~/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/
/// EBWebView/WV2Profile_*/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb` (one profile
/// folder per signed-in account, plus a `.blob` sibling for large values). Three of its databases
/// matter, by name prefix:
/// - `Teams:conversation-manager:`, store `conversations`: one row per chat, meeting chat or
///   channel, with its topic and members' ids;
/// - `Teams:replychain-manager:`, stores `replychains` and `replychains-2`: messages grouped in
///   reply chains (`messageMap`), each with its sender, arrival time and HTML content;
/// - `Teams:profiles:`, store `profiles`: display names by member id (`mri`, `displayName`).
///
/// How it is read: in place, read-only, while Teams may be writing (`LevelDBReader` copes with
/// compactions and unfinished writes), with the container's access granted by Full Disk Access like
/// the other protected stores. Nothing is copied to disk. The layers below are format readers
/// (`LevelDBReader` -> `IndexedDBReader` -> `V8ValueDeserializer`); this type picks the databases
/// above and hands their rows to `TeamsMessageMapper`, which holds the rules, then wraps the result
/// as `MemoryIngestRecord`s.
///
/// Paging and the cursor: the cache is not a table with row ids, and decoding it is one pass over
/// every file, so a read returns everything after the cursor in one page (`hasMore` false); the
/// engine's upsert makes repeated records free. The cursor is the newest arrival time seen (epoch
/// milliseconds), and each read starts two days before it, so messages edited after they were
/// first remembered are stored again with their new text. The cursor never moves back.
///
/// What it is not: complete. Teams caches what it has displayed and synced, typically the recent
/// months of active chats; older history exists only in Microsoft 365. The schema is undocumented
/// and can change with any Teams update, so every field is read defensively.
nonisolated struct TeamsCacheReader: MemoryHistoryReading {
    let sourceID = "teams"
    let webViewRoot: String
    /// IndexedDB folders to read instead of discovering the profiles (tests).
    private let explicitFolders: [String]?

    static let originFolder = "https_teams.microsoft.com_0.indexeddb"
    /// How far before the cursor each read starts again, to pick up edited messages.
    static let lookbackMilliseconds: Double = 2 * 86_400 * 1000

    static let conversationDatabasePrefix = "Teams:conversation-manager:"
    static let replyChainDatabasePrefix = "Teams:replychain-manager:"
    static let profileDatabasePrefix = "Teams:profiles:"

    init(webViewRoot: String = NSHomeDirectory()
        + "/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView") {
        self.webViewRoot = webViewRoot
        self.explicitFolders = nil
    }

    /// Reads exactly these `….indexeddb.leveldb` folders (their `.blob` siblings are found by name).
    init(indexedDBFolders: [String]) {
        self.webViewRoot = indexedDBFolders.first ?? ""
        self.explicitFolders = indexedDBFolders
    }

    /// One IndexedDB folder per signed-in Teams profile (work and personal accounts are separate).
    func indexedDBFolders() throws -> [String] {
        if let explicitFolders { return explicitFolders }
        let profiles = try FileManager.default.contentsOfDirectory(atPath: webViewRoot)
            .filter { $0.hasPrefix("WV2Profile_") }
            .sorted()
        return profiles.compactMap { profile in
            let path = "\(webViewRoot)/\(profile)/IndexedDB/\(Self.originFolder).leveldb"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return path
        }
    }

    func readiness() -> MemorySourceReadiness {
        guard explicitFolders != nil || FileManager.default.fileExists(atPath: webViewRoot) else {
            return .notFound("No Teams cache on this Mac. Open the new Teams app once.")
        }
        let folders: [String]
        do {
            folders = try indexedDBFolders()
        } catch {
            return LevelDBReader.isPermissionError(error) ? .needsFullDiskAccess : .failed(error.localizedDescription)
        }
        guard let first = folders.first else {
            return .notFound("Teams has not cached any chats yet.")
        }
        // Listing can be allowed while reading is not; open one file to be sure.
        let descriptor = open(first + "/CURRENT", O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .ready
        }
        return errno == EPERM || errno == EACCES ? .needsFullDiskAccess : .failed("Cannot read the Teams cache.")
    }

    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage {
        // The cursor is the newest message time in milliseconds ("1791034747629" or
        // "1791034747629.0"; both forms parse). A stored cursor outside real Teams times (from a
        // corrupt value) would hide every message; start over instead (the store's upsert is idempotent).
        let stored = cursor.flatMap(Double.init) ?? 0
        let previous = stored.isFinite && stored <= TeamsMessageMapper.latestAcceptedMilliseconds ? stored : 0
        let after = previous > 0 ? max(0, previous - Self.lookbackMilliseconds) : 0
        let result = try readCache(afterMilliseconds: after)
        let sinceMilliseconds = (since?.timeIntervalSince1970 ?? 0) * 1000
        let records = result.messages
            .filter { $0.arrivalMilliseconds >= sinceMilliseconds }
            .map { message in
                MemoryIngestRecord(
                    sourceMessageID: message.sourceMessageID,
                    conversationID: message.conversationID,
                    conversationTitle: message.conversationTitle,
                    sender: message.sender,
                    isFromMe: message.isFromMe,
                    timestamp: message.timestamp,
                    text: message.text,
                    participants: message.participants,
                    subject: nil
                )
            }
        let newest = max(previous, result.newestMilliseconds)
        return MemoryReadPage(
            records: records,
            nextCursor: newest > previous ? String(format: "%.0f", newest.rounded(.down)) : nil,
            hasMore: false
        )
    }

    /// Every cached message that arrived after `afterMilliseconds`, mapped, across all profiles.
    /// Each profile is mapped on its own: each is a signed-in account with its own user, and
    /// pooling them would make one account's user everyone's "You".
    func readCache(afterMilliseconds: Double) throws -> TeamsMessageMapper.Result {
        let folders: [String]
        do {
            folders = try indexedDBFolders()
        } catch {
            if LevelDBReader.isPermissionError(error) { throw ReadOnlySQLiteDatabase.DatabaseError.notPermitted(webViewRoot) }
            throw ReadOnlySQLiteDatabase.DatabaseError.missing(webViewRoot)
        }
        guard !folders.isEmpty else { throw ReadOnlySQLiteDatabase.DatabaseError.missing(webViewRoot) }

        var messages: [TeamsMessageMapper.Message] = []
        var newest = afterMilliseconds
        for folder in folders {
            let rows: Rows
            do {
                rows = try readRows(folder: folder)
            } catch LevelDBReader.ReadError.notPermitted(let path) {
                throw ReadOnlySQLiteDatabase.DatabaseError.notPermitted(path)
            }
            let mapped = TeamsMessageMapper.map(
                conversations: rows.conversations, messages: rows.messages, profiles: rows.profiles,
                afterMilliseconds: afterMilliseconds
            )
            messages += mapped.messages
            newest = max(newest, mapped.newestMilliseconds)
        }
        return TeamsMessageMapper.Result(messages: messages, newestMilliseconds: newest)
    }

    /// The fields `TeamsMessageMapper` reads. A cached message carries dozens more (reactions,
    /// cards, properties); copying only these keeps a large cache's rows small.
    static let messageFields = [
        "id", "conversationId", "creator", "imDisplayName", "fromDisplayNameInToken", "content", "messageType",
        "originalArrivalTime", "clientArrivalTime", "deletionInfo"
    ]
    static let conversationFields = ["id", "threadProperties", "members"]

    static func fields(_ names: [String], of object: V8Object) -> [String: Any] {
        var result: [String: Any] = [:]
        for name in names {
            if let value = object[name] { result[name] = value.plainValue }
        }
        return result
    }

    /// The decoded rows of one profile's cache, before any mapping.
    struct Rows {
        var conversations: [[String: Any]] = []
        var messages: [[String: Any]] = []
        var profiles: [String: String] = [:]
    }

    func readRows(folder: String) throws -> Rows {
        let levelDB = URL(fileURLWithPath: folder)
        let blobPath = (folder.hasSuffix(".leveldb") ? String(folder.dropLast(".leveldb".count)) : folder) + ".blob"
        let blobFolder = FileManager.default.fileExists(atPath: blobPath) ? URL(fileURLWithPath: blobPath) : nil
        let prefixes = [Self.conversationDatabasePrefix, Self.replyChainDatabasePrefix, Self.profileDatabasePrefix]
        var database = try IndexedDBReader(levelDBFolder: levelDB, blobFolder: blobFolder) { name in
            prefixes.contains { name.hasPrefix($0) }
        }

        var rows = Rows()
        for entry in database.databases {
            if entry.name.hasPrefix(Self.conversationDatabasePrefix) {
                database.forEachValue(in: entry, stores: ["conversations"]) { value in
                    guard case .object(let row) = value else { return }
                    rows.conversations.append(Self.fields(Self.conversationFields, of: row))
                }
            } else if entry.name.hasPrefix(Self.replyChainDatabasePrefix) {
                database.forEachValue(in: entry, stores: ["replychains", "replychains-2"]) { value in
                    // Messages in the chain's own order: the mapper's tie-breaks follow input order.
                    guard case .object(let chain) = value, case .object(let messageMap)? = chain["messageMap"] else { return }
                    for case .object(let message) in messageMap.values {
                        rows.messages.append(Self.fields(Self.messageFields, of: message))
                    }
                }
            } else if entry.name.hasPrefix(Self.profileDatabasePrefix) {
                database.forEachValue(in: entry, stores: ["profiles"]) { value in
                    guard case .object(let profile) = value, case .string(let mri)? = profile["mri"],
                          case .string(let name)? = profile["displayName"] else { return }
                    let display = PythonText.strip(name)
                    if !display.isEmpty { rows.profiles[mri] = display }
                }
            }
        }
        if database.undecodableRecords > 0 {
            CotabbyLogger.app.warning("Teams cache: skipped records that could not be decoded", metadata: [
                "count": .stringConvertible(database.undecodableRecords)
            ])
        }
        return rows
    }
}
