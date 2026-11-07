import Foundation

/// File overview:
/// The values conversation memory's engine, its settings file and the Memory pane share.
///
/// `MemoryConfiguration` is the user's memory settings, persisted as `config.json` in the memory
/// data folder with snake_case keys (unknown keys are ignored and missing ones take their defaults,
/// so a file written by another version still loads). The rest are read-only values the
/// engine produces for the pane and for suggestions. Keeping them in one file makes a change to
/// what memory exposes one reviewable diff.

/// How memory is searched (`config.index`).
nonisolated struct MemoryIndexSettings: Codable, Equatable, Sendable {
    /// Messages retrieved per lookup.
    var topK: Int = 4
    /// 1 = rank by meaning only, 0 = by shared words only.
    var vectorWeight: Double = 0.7
    /// Words per embedded passage, and the overlap between a long mail's passages.
    var chunkSize: Int = PassageChunker.defaultSize
    var chunkOverlap: Int = PassageChunker.defaultOverlap

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topK = min(max(try container.decodeIfPresent(Int.self, forKey: .topK) ?? 4, 1), 20)
        vectorWeight = min(max(try container.decodeIfPresent(Double.self, forKey: .vectorWeight) ?? 0.7, 0), 1)
        chunkSize = min(max(try container.decodeIfPresent(Int.self, forKey: .chunkSize) ?? PassageChunker.defaultSize, 64), 400)
        let overlap = try container.decodeIfPresent(Int.self, forKey: .chunkOverlap) ?? PassageChunker.defaultOverlap
        chunkOverlap = min(max(overlap, 0), chunkSize / 2)
    }

    /// The same settings within their bounds, the overlap at most half a passage (a smaller
    /// passage size must take a larger overlap down with it).
    func clamped() -> MemoryIndexSettings {
        var settings = self
        settings.topK = min(max(topK, 1), 20)
        settings.vectorWeight = min(max(vectorWeight, 0), 1)
        settings.chunkSize = min(max(chunkSize, 64), 400)
        settings.chunkOverlap = min(max(chunkOverlap, 0), settings.chunkSize / 2)
        return settings
    }
}

/// One source's saved settings (`config.sources[id]`).
nonisolated struct MemorySourceSettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var options: [String: String]

    init(enabled: Bool, options: [String: String] = [:]) {
        self.enabled = enabled
        self.options = options
    }

    /// Options are free-form JSON in the file; any non-string value is kept as its text rather than
    /// failing the whole configuration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let raw = try container.decodeIfPresent([String: MemoryJSONValue].self, forKey: .options) ?? [:]
        options = raw.mapValues(\.text)
    }
}

/// `config.privacy`.
nonisolated struct MemoryPrivacySettings: Codable, Equatable, Sendable {
    var excludedConversations: [String] = []
    var excludedParticipants: [String] = []
    /// Messages older than this many days are not stored (and are purged); 0 keeps everything.
    var retentionDays: Int = 365

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedConversations = try container.decodeIfPresent([String].self, forKey: .excludedConversations) ?? []
        excludedParticipants = try container.decodeIfPresent([String].self, forKey: .excludedParticipants) ?? []
        retentionDays = max(0, try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 365)
    }
}

/// Everything the user configures about memory.
nonisolated struct MemoryConfiguration: Codable, Equatable, Sendable {
    var index = MemoryIndexSettings()
    var sources: [String: MemorySourceSettings] = [:]
    var privacy = MemoryPrivacySettings()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(MemoryIndexSettings.self, forKey: .index) ?? MemoryIndexSettings()
        sources = try container.decodeIfPresent([String: MemorySourceSettings].self, forKey: .sources) ?? [:]
        privacy = try container.decodeIfPresent(MemoryPrivacySettings.self, forKey: .privacy) ?? MemoryPrivacySettings()
    }

    /// Sources the user switched on.
    var enabledSourceIDs: [String] {
        sources.filter(\.value.enabled).keys.sorted()
    }
}

/// One memory source as the pane shows it: what it is, its settings, and what is stored from it.
nonisolated struct MemorySource: Equatable, Identifiable, Sendable {
    struct Requirement: Equatable, Sendable {
        let kind: String
        let title: String
        let detail: String
    }

    struct Stats: Equatable, Sendable {
        let messages: Int
        let pending: Int
        let conversations: Int
        let newestTimestamp: Double?
        let lastSync: Double?

        static let empty = Stats(messages: 0, pending: 0, conversations: 0, newestTimestamp: nil, lastSync: nil)
    }

    let id: String
    let title: String
    let description: String
    /// The apps whose fields this source's memory serves.
    let appBundleIds: [String]
    let requirements: [Requirement]
    /// Option keys the pane edits, with a label each (a folder for Documents).
    let optionsSchema: [String: String]
    let enabled: Bool
    let options: [String: String]
    let stats: Stats
}

/// A conversation memory knows.
nonisolated struct MemoryConversation: Equatable, Hashable, Sendable {
    let source: String
    let conversationId: String
    let title: String
    let participants: [String]
    let lastTimestamp: Double
}

/// What memory returned for one query, and how widely it had to look.
nonisolated struct MemorySearchResult: Equatable, Sendable {
    struct Hit: Equatable, Identifiable, Sendable {
        let recordId: String
        let source: String
        let conversationId: String
        let conversationTitle: String
        let sender: String
        let isFromMe: Bool
        let timestamp: Double
        let subject: String?
        let text: String
        let score: Double
        /// Cosine similarity of the best passage (0 when only keyword search found it).
        let similarity: Double
        /// "vector", "keyword" or "both": which retrieval path found it.
        let via: String

        var id: String { recordId }
    }

    /// "conversation", "person", "global", or "none" when the conversation was not recognized.
    let scope: String
    let conversation: MemoryConversation?
    let elapsedMs: Double
    let hits: [Hit]

    static let empty = MemorySearchResult(scope: "none", conversation: nil, elapsedMs: 0, hits: [])
}

/// What the engine reports about its index and background work, for the pane.
nonisolated struct MemoryEngineStatus: Equatable, Sendable {
    /// Passages in the in-memory index.
    var passages = 0
    /// Messages stored but not yet searchable by meaning.
    var pendingMessages = 0
    /// Resident size of the vectors.
    var vectorBytes = 0
    /// What background indexing is doing or waiting for ("Indexing 1,200 of 31,000", "Waiting for power").
    var activity = ""
    var isIndexing = false
    /// Passages embedded per second during the last indexing run.
    var passagesPerSecond: Double?

    // Figures for the pane's statistics.
    /// How long recent searches took, end to end inside the engine (embedding the query, scanning
    /// the vectors, keyword lookup, reading and decrypting the hits).
    var searchLatency = MemoryLatencyStats()
    /// The query-embedding part of those searches (the model's share).
    var queryEmbeddingLatency = MemoryLatencyStats()
    /// The encrypted store on disk, its write-ahead log included.
    var databaseBytes: Int64 = 0
    /// The embedding model file.
    var modelBytes: Int64 = 0
    var modelName = ""
    /// Numbers per vector (the model's embedding width).
    var dimensions = 0
}

/// A JSON value of any type, for the free-form option values a settings file may hold.
nonisolated enum MemoryJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case other(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .other("")
        }
    }

    var text: String {
        switch self {
        case .string(let value): return value
        // `Int(exactly:)`: a whole number beyond Int's range (1e20 in a hand-edited file) stays a
        // Double instead of trapping at launch.
        case .number(let value): return Int(exactly: value).map(String.init) ?? String(value)
        case .bool(let value): return value ? "true" : "false"
        case .other(let value): return value
        }
    }
}
