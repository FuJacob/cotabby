import Foundation

/// File overview:
/// The contract between Cotabby's readers of protected message stores and the memory sync that
/// hands their messages to the engine (`MemoryEngine.ingest`).
///
/// Readers run on a background task, open their store read-only, and return messages in a stable
/// order after a cursor they define (a row id), a page at a time, so a sync can stop and resume
/// anywhere. Everything after reading (scrubbing, exclusions, encryption, indexing) happens in the
/// engine, the same for every source.

/// One message as a reader produces it and `MemoryEngine.ingest` takes it.
nonisolated struct MemoryIngestRecord: Equatable, Sendable {
    let sourceMessageID: String
    let conversationID: String
    let conversationTitle: String
    let sender: String
    let isFromMe: Bool
    let timestamp: Date
    let text: String
    /// The other people in the conversation, as stable identities (WhatsApp JIDs, mail addresses).
    let participants: [String]
    /// Mail only; its presence also tells the engine to strip quoted history.
    let subject: String?
}

nonisolated struct MemoryReadPage: Sendable {
    let records: [MemoryIngestRecord]
    /// Where the next page starts; nil when the store had nothing after the cursor.
    let nextCursor: String?
    /// True when there may be more after this page.
    let hasMore: Bool
    /// Conversations whose every record is in this page (a document read whole). Memory drops what
    /// it held for them that the page no longer has, so a shortened file loses its old tail.
    var completeConversations: Set<String> = []
}

nonisolated protocol MemoryHistoryReading: Sendable {
    /// The memory source id (`whatsapp`, `apple_mail`; see `MemorySourceCatalog`).
    var sourceID: String { get }
    /// Whether the store can be read right now: present, and permitted by macOS.
    func readiness() -> MemorySourceReadiness
    /// Up to `limit` messages after `cursor` (or from `since` when there is no cursor).
    func read(after cursor: String?, since: Date?, limit: Int) throws -> MemoryReadPage
    /// Every conversation the source still has, for sources whose items can disappear (deleted
    /// documents): after a full sync, memory forgets the rest. Nil (the default) when the source
    /// cannot tell, which never removes anything.
    func liveConversationIDs() -> Set<String>?
}

nonisolated extension MemoryHistoryReading {
    func liveConversationIDs() -> Set<String>? { nil }
}

nonisolated enum MemorySourceReadiness: Equatable, Sendable {
    case ready
    /// The app is not installed or has no local history yet.
    case notFound(String)
    /// macOS denied access; Cotabby needs Full Disk Access.
    case needsFullDiskAccess
    case failed(String)

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .ready: return "Ready"
        case .notFound(let detail): return detail
        case .needsFullDiskAccess: return "Cotabby needs Full Disk Access to read this history."
        case .failed(let detail): return detail
        }
    }
}

extension ReadOnlySQLiteDatabase.DatabaseError {
    nonisolated var readiness: MemorySourceReadiness {
        switch self {
        case .notPermitted: return .needsFullDiskAccess
        case .missing(let path): return .notFound("No local history at \(path).")
        case .sqlite(let message): return .failed(message)
        }
    }
}
