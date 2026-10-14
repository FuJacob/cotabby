import CryptoKit
import Foundation
import Logging

/// File overview:
/// Conversation memory, in-process: ingest, background indexing and search over the encrypted store.
///
/// Responsibilities:
/// - **Ingest**: the pipeline every message passes whichever reader produced it (exclusions,
///   retention, mail quote stripping, secret scrubbing), then the encrypted `MemoryStore`.
/// - **Indexing**: a background loop embeds stored messages with `EmbeddingCore` (llama.cpp) when
///   `EmbeddingSchedulePolicy` allows it, newest first, persisting each vector as it is computed so
///   an interrupted run resumes where it stopped, and keeps `FlatVectorIndex` in step.
/// - **Search**: the scope rule suggestions rely on (this conversation, then conversations with
///   exactly the same people, never a guess on an ambiguous title), and the Playground's wider
///   exploring search over every enabled source.
///
/// Lifetime and threading: built by `MemoryEngineController` when memory is switched on and dropped
/// when it is switched off. Every method is synchronous and thread-safe (the store, the index and
/// the configuration each have their own lock) and is called off the main actor; the indexing loop
/// is its own task. Nothing leaves the Mac, and nothing here talks to an endpoint model.
nonisolated final class MemoryEngine: @unchecked Sendable {
    struct Paths: Sendable {
        let dataDirectory: URL
        var store: URL { dataDirectory.appendingPathComponent("messages.sqlite") }
        var configuration: URL { dataDirectory.appendingPathComponent("config.json") }
    }

    /// The scope of a suggestion's search.
    struct Scope: Hashable, Sendable {
        /// The chat name or mail subject the focused window shows.
        var title: String?
        /// The sources serving the focused app; titles never match outside them.
        var sources: [String] = []
        /// An exact conversation (the Playground's picker).
        var conversation: (source: String, conversationID: String)?
        /// Everything (the Playground's exploring mode; suggestions never use it).
        var global = false
        /// When not empty (a mail reply's quote header addresses), these minus the user's own
        /// addresses must be exactly the people of the conversation found by title; an address
        /// memory does not know is another person. Otherwise it is not this conversation.
        var requiredParticipants: Set<String> = []

        static func == (lhs: Scope, rhs: Scope) -> Bool {
            lhs.title == rhs.title && lhs.sources == rhs.sources && lhs.global == rhs.global
                && lhs.requiredParticipants == rhs.requiredParticipants
                && lhs.conversation?.source == rhs.conversation?.source
                && lhs.conversation?.conversationID == rhs.conversation?.conversationID
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(sources)
            hasher.combine(global)
            hasher.combine(requiredParticipants)
            hasher.combine(conversation?.source)
            hasher.combine(conversation?.conversationID)
        }
    }

    let paths: Paths
    let modelIdentifier: String
    private let modelPath: String
    private let store: MemoryStore
    private let embedding = EmbeddingCore()
    private let index = FlatVectorIndex(dimensions: 0)
    private let conditions: @Sendable () async -> EmbeddingSchedulePolicy.Conditions

    private let configurationLock = NSLock()
    private var configurationValue: MemoryConfiguration

    private let statusLock = NSLock()
    private var statusValue = MemoryEngineStatus()
    /// Called with every status change, on an arbitrary thread.
    var onStatusChange: (@Sendable (MemoryEngineStatus) -> Void)?

    private var indexingTask: Task<Void, Never>?
    /// Set once the engine is being stopped: a sync still holding it must not write any more.
    private let stoppedLock = NSLock()
    private var stopped = false
    private let wakeLock = NSLock()
    private var wakeRequested = false

    /// Messages read per indexing step, and passages embedded per native call (small, so a query
    /// waiting for the model waits for at most one call).
    static let messagesPerStep = 32
    static let passagesPerCall = 8

    /// Opens the store with the root key and loads the settings. Throws `MemoryVault.VaultError
    /// .keyMismatch` when the store was encrypted with another key.
    init(
        paths: Paths, rootKey: SymmetricKey, modelURL: URL,
        conditions: @escaping @Sendable () async -> EmbeddingSchedulePolicy.Conditions
    ) throws {
        self.paths = paths
        self.conditions = conditions
        modelPath = modelURL.path
        let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        modelIdentifier = "\(modelURL.deletingPathExtension().lastPathComponent)@\(size)"
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        store = try MemoryStore(path: paths.store, vault: MemoryVault(rootKey: rootKey))
        configurationValue = Self.loadConfiguration(paths.configuration)
        statusValue.modelBytes = size
        statusValue.modelName = modelURL.deletingPathExtension().lastPathComponent
    }

    deinit {
        indexingTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Loads the embedding model and the index, applies retention, and starts background indexing.
    func start() throws {
        try embedding.load(modelPath: modelPath)
        if try store.invalidateVectors(notMadeBy: modelIdentifier) > 0 {
            log("embedding model changed; messages will be indexed again")
        }
        try purgeForPrivacy()
        reloadIndex()
        indexingTask?.cancel()
        indexingTask = Task.detached(priority: .utility) { [weak self] in
            await self?.indexingLoop()
        }
    }

    func stop() {
        markStopped()
        indexingTask?.cancel()
        indexingTask = nil
        embedding.unload()
    }

    /// Makes every later `ingest` a no-op. Cheap and synchronous, so the controller calls it the
    /// moment memory is switched off, before the slower `stop` runs off the main actor.
    func markStopped() {
        stoppedLock.lock()
        stopped = true
        stoppedLock.unlock()
    }

    var isStopped: Bool {
        stoppedLock.lock()
        defer { stoppedLock.unlock() }
        return stopped
    }

    private func reloadIndex() {
        let vectors = (try? store.vectors(model: modelIdentifier)) ?? []
        index.replaceAll(vectors)
        updateStatus { status in
            status.passages = self.index.count
            status.vectorBytes = self.index.byteSize
            status.dimensions = self.index.dimensions
            status.databaseBytes = self.databaseBytes()
        }
    }

    /// The store's size on disk: the database and its write-ahead log (recent writes not yet folded
    /// into the database live there, sometimes tens of megabytes).
    private func databaseBytes() -> Int64 {
        [paths.store.path, paths.store.path + "-wal"].reduce(Int64(0)) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - Configuration

    var configuration: MemoryConfiguration {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return configurationValue
    }

    /// Applies a change to the settings and saves them, then does what the change requires: purge
    /// what privacy now excludes, or re-index when passages are cut differently.
    func updateConfiguration(_ change: (inout MemoryConfiguration) -> Void) throws {
        configurationLock.lock()
        let before = configurationValue
        change(&configurationValue)
        let after = configurationValue
        configurationLock.unlock()
        try Self.saveConfiguration(after, to: paths.configuration)
        if after.privacy != before.privacy {
            try purgeForPrivacy()
            reloadIndex()
        }
        if after.index.chunkSize != before.index.chunkSize || after.index.chunkOverlap != before.index.chunkOverlap {
            try store.resetIndex()
            reloadIndex()
        }
        wakeIndexing()
    }

    static func loadConfiguration(_ url: URL) -> MemoryConfiguration {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: url),
              let configuration = try? decoder.decode(MemoryConfiguration.self, from: data) else { return MemoryConfiguration() }
        return configuration
    }

    static func saveConfiguration(_ configuration: MemoryConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private var enabledSources: [String] {
        configuration.enabledSourceIDs.filter { MemorySourceCatalog.descriptor($0) != nil }
    }

    // MARK: - Sources

    func sources() -> [MemorySource] {
        let configuration = configuration
        return MemorySourceCatalog.all.map { descriptor in
            let settings = configuration.sources[descriptor.id]
            let stats = (try? store.sourceStats(descriptor.id)).map {
                MemorySource.Stats(messages: $0.messages, pending: $0.pending, conversations: $0.conversations,
                                   newestTimestamp: $0.newestTimestamp, lastSync: $0.lastSync)
            } ?? .empty
            return MemorySource(
                id: descriptor.id, title: descriptor.title, description: descriptor.description,
                appBundleIds: descriptor.appBundleIds, requirements: descriptor.requirements,
                optionsSchema: descriptor.optionsSchema, enabled: settings?.enabled ?? false,
                options: settings?.options ?? [:], stats: stats
            )
        }
    }

    func cursor(source: String) -> String? {
        try? store.cursor(source: source)
    }

    /// Deletes everything stored from one source.
    func forget(source: String) throws {
        try store.deleteSource(source)
        reloadIndex()
    }

    /// Embeds every stored message again.
    func rebuildIndex() throws {
        try store.resetIndex()
        reloadIndex()
        wakeIndexing()
    }

    /// Forgets every message, vector and cursor. Settings stay.
    func deleteEverything() throws {
        try store.deleteEverything()
        reloadIndex()
    }

    // MARK: - Ingest

    struct IngestResult: Equatable, Sendable {
        let stored: Int
        let dropped: Int
    }

    /// The pipeline every message passes: exclusions, retention, mail quote stripping, secret
    /// scrubbing, then the encrypted store. `cursor` is saved after the records, so an interrupted
    /// sync resumes after the last batch stored.
    @discardableResult
    func ingest(
        source: String, records: [MemoryIngestRecord], cursor: String?, completeConversations: Set<String> = [],
        ownAddresses: Set<String> = []
    ) throws -> IngestResult {
        let configuration = configuration
        guard !isStopped, configuration.sources[source]?.enabled == true else {
            return IngestResult(stored: 0, dropped: records.count)
        }
        let excludedConversations = Set(configuration.privacy.excludedConversations)
        let excludedPeople = Set(configuration.privacy.excludedParticipants.map(ParticipantNormalizer.normalize))
        let cutoff = retentionCutoff(configuration)
        var kept: [MemoryIngestRecord] = []
        var dropped = 0
        for record in records {
            let people = Set((record.participants + [record.sender]).map(ParticipantNormalizer.normalize))
            if excludedConversations.contains(record.conversationID) || !excludedPeople.isDisjoint(with: people)
                || (!MemorySourceCatalog.keepsAllDates(source) && (cutoff.map { record.timestamp < $0 } ?? false)) {
                dropped += 1
                continue
            }
            let text = record.subject != nil ? MailQuoteStripper.strip(record.text) : record.text
            guard let cleaned = MemoryTextScrubber.scrub(text) else {
                dropped += 1
                continue
            }
            kept.append(MemoryIngestRecord(
                sourceMessageID: record.sourceMessageID, conversationID: record.conversationID,
                conversationTitle: record.conversationTitle, sender: record.sender, isFromMe: record.isFromMe,
                timestamp: record.timestamp, text: cleaned, participants: record.participants, subject: record.subject
            ))
        }
        // The addresses the user sends from, so a mail reply's own address is recognised (see
        // `isSameAudience`).
        try store.addOwnAddresses(ownAddresses, source: source)
        var stored = 0
        // Short transactions, so a search never waits behind a whole sync.
        for start in stride(from: 0, to: kept.count, by: 200) {
            let result = try store.upsert(source: source, records: Array(kept[start..<min(start + 200, kept.count)]))
            stored += result.changed
            index.remove(recordIDs: Set(result.replacedRecordIDs))
        }
        if let cursor { try store.setCursor(cursor, source: source) }
        if !completeConversations.isEmpty {
            // Read whole: what memory held for them beyond this page's records is gone from the source.
            let kept = Set(kept.map { store.recordID(source: source, sourceMessageID: $0.sourceMessageID) })
            let removed = try store.removeRecords(source: source, inConversations: completeConversations, notIn: kept)
            if !removed.isEmpty { index.remove(recordIDs: Set(removed)) }
        }
        updateStatus { $0.databaseBytes = self.databaseBytes() }
        if stored > 0 { wakeIndexing() }
        return IngestResult(stored: stored, dropped: dropped)
    }

    private func retentionCutoff(_ configuration: MemoryConfiguration) -> Date? {
        configuration.privacy.retentionDays > 0
            ? Date().addingTimeInterval(-Double(configuration.privacy.retentionDays) * 86_400) : nil
    }

    /// Forgets the conversations of `source` that it no longer has (`MemoryHistoryReading
    /// .liveConversationIDs`: documents deleted from their drive). Returns how many records went.
    @discardableResult
    func forget(source: String, conversationsNotIn live: Set<String>) throws -> Int {
        let removed = try store.removeConversations(source: source, notIn: live)
        if !removed.isEmpty {
            index.remove(recordIDs: Set(removed))
            updateStatus { status in
                status.passages = self.index.count
                status.vectorBytes = self.index.byteSize
            }
        }
        return removed.count
    }

    private func purgeForPrivacy() throws {
        let privacy = configuration.privacy
        let removed = try store.purge(
            excludedConversations: privacy.excludedConversations, excludedParticipants: privacy.excludedParticipants,
            olderThan: retentionCutoff(configuration)?.timeIntervalSince1970,
            keepingAllOf: MemorySourceCatalog.sourcesKeepingAllDates
        )
        if removed > 0 { log("purged \(removed) messages for privacy settings") }
    }

    // MARK: - Indexing

    func wakeIndexing() {
        wakeLock.lock()
        wakeRequested = true
        wakeLock.unlock()
    }

    private func takeWake() -> Bool {
        wakeLock.lock()
        defer { wakeLock.unlock() }
        let requested = wakeRequested
        wakeRequested = false
        return requested
    }

    private func indexingLoop() async {
        var embeddedThisRun = 0
        var runStarted = Date()
        while !Task.isCancelled {
            let sources = enabledSources
            let pending = (try? store.unindexedCount(sources: sources)) ?? 0
            var current = await conditions()
            current.pendingPassages = pending
            switch EmbeddingSchedulePolicy.decide(current) {
            case .wait(let reason):
                if embeddedThisRun > 0 { log("indexed \(embeddedThisRun) passages") }
                embeddedThisRun = 0
                updateStatus { status in
                    status.pendingMessages = pending
                    status.isIndexing = false
                    status.activity = pending == 0 ? "Up to date" : reason
                }
                // Sleep up to 30 s, waking early when new messages arrive.
                for _ in 0..<30 where !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if takeWake() { break }
                }
            case .run:
                if embeddedThisRun == 0 { runStarted = Date() }
                do {
                    embeddedThisRun += try indexStep(sources: sources)
                } catch {
                    log("indexing step failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                let elapsed = Date().timeIntervalSince(runStarted)
                let remaining = (try? store.unindexedCount(sources: sources)) ?? 0
                updateStatus { status in
                    status.pendingMessages = remaining
                    status.isIndexing = remaining > 0
                    status.passages = self.index.count
                    status.vectorBytes = self.index.byteSize
                    status.passagesPerSecond = elapsed > 1 ? Double(embeddedThisRun) / elapsed : status.passagesPerSecond
                    status.dimensions = self.index.dimensions
                    status.databaseBytes = self.databaseBytes()
                    status.activity = remaining > 0 ? "Indexing: \(remaining) messages to go" : "Up to date"
                }
                await Task.yield()
            }
        }
    }

    /// One passage to embed: which message of the step it came from, its stored id, and its text.
    private struct PendingPassage {
        let message: Int
        let passageID: String
        let text: String
    }

    /// Embeds one step of unindexed messages and stores their vectors. Returns passages embedded.
    private func indexStep(sources: [String]) throws -> Int {
        let messages = try store.unindexedMessages(sources: sources, limit: Self.messagesPerStep)
        guard !messages.isEmpty else { return 0 }
        let settings = configuration.index
        var passages: [PendingPassage] = []
        for (position, message) in messages.enumerated() {
            let text = PassageChunker.passageText(
                timestamp: Date(timeIntervalSince1970: message.timestamp), sender: message.sender,
                isFromMe: message.isFromMe, subject: message.subject, text: message.text
            )
            for (number, chunk) in PassageChunker.chunks(text, size: settings.chunkSize, overlap: settings.chunkOverlap).enumerated() {
                let passageID = number == 0 ? message.recordID : "\(message.recordID)#\(number)"
                passages.append(PendingPassage(message: position, passageID: passageID, text: chunk))
            }
        }
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: passages.count, by: Self.passagesPerCall) {
            guard !Task.isCancelled else { return 0 }
            let slice = passages[start..<min(start + Self.passagesPerCall, passages.count)]
            vectors += try embedding.embedPassages(slice.map(\.text))
        }
        var grouped: [Int: [(passageID: String, vector: [UInt16])]] = [:]
        for (passage, vector) in zip(passages, vectors) {
            grouped[passage.message, default: []].append((passage.passageID, HalfPrecision.encode(vector)))
        }
        let entries = messages.enumerated().map { (message: $0.element, passages: grouped[$0.offset] ?? []) }
        try store.saveIndexEntries(entries, model: modelIdentifier)
        index.upsert(entries.flatMap { entry in
            entry.passages.map {
                MemoryStore.StoredVector(passageID: $0.passageID, recordID: entry.message.recordID, source: entry.message.source,
                                         conversationKey: entry.message.conversationKey, timestamp: entry.message.timestamp,
                                         vector: $0.vector)
            }
        })
        return passages.count
    }

    // MARK: - Search

    /// A suggestion's search: the conversation the window names, then, only when that has too few
    /// matches, conversations with exactly the same people. An unknown or ambiguous conversation
    /// returns nothing, never wider results.
    func search(query: String, scope: Scope, topK: Int? = nil) -> MemorySearchResult {
        let started = Date()
        let topK = min(max(topK ?? configuration.index.topK, 1), 20)
        let enabled = Set(enabledSources)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        if scope.global {
            let wanted = scope.sources.isEmpty ? enabled : enabled.intersection(scope.sources)
            let hits = hybrid(query: trimmed, task: .conversationContext, topK: topK,
                              vectorFilter: { wanted.contains($0.source) },
                              keyword: { try self.store.taggedKeywordSearch(query: trimmed, sources: Array(wanted), limit: topK * 3) })
            return result("global", nil, hits, started)
        }

        guard let conversation = resolve(scope, enabled: enabled) else { return result("none", nil, [], started) }
        let ownKey = store.conversationKey(source: conversation.source, conversationID: conversation.conversationId)
        let own = [(source: conversation.source, conversationKey: ownKey)]
        var hits = scopedHybrid(query: trimmed, conversations: own, topK: topK)
        var scopeName = "conversation"
        if hits.count < topK, !conversation.participants.isEmpty {
            let related = ((try? store.conversationsSeenBy(
                audience: conversation.participants, excluding: (conversation.source, ownKey)
            )) ?? []).filter { enabled.contains($0.source) }
            if !related.isEmpty {
                let seen = Set(hits.map(\.recordId))
                let extra = scopedHybrid(query: trimmed, conversations: related, topK: topK - hits.count)
                    .filter { !seen.contains($0.recordId) }
                if !extra.isEmpty {
                    scopeName = "person"
                    hits += extra
                }
            }
        }
        return result(scopeName, conversation, hits, started)
    }

    func recentConversations(sources: [String], limit: Int) -> [MemoryConversation] {
        let enabled = Set(enabledSources)
        return (try? store.recentConversations(sources: sources.filter(enabled.contains), limit: limit)) ?? []
    }

    var status: MemoryEngineStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return statusValue
    }

    // MARK: - Search internals

    /// The conversation a scope names: an exact id, or a title matched only within the app's
    /// sources. A title shared by several conversations cannot say which one is being written in,
    /// and guessing would hand one conversation's messages to another, so ambiguous means none.
    private func resolve(_ scope: Scope, enabled: Set<String>) -> MemoryConversation? {
        if let exact = scope.conversation {
            guard enabled.contains(exact.source) else { return nil }
            return try? store.conversation(source: exact.source, conversationID: exact.conversationID)
        }
        let sources = scope.sources.filter(enabled.contains)
        guard let title = scope.title, !title.isEmpty, !sources.isEmpty,
              let found = try? store.findConversations(title: title, sources: sources) else { return nil }
        // A mail reply: of the conversations with this subject (one per audience), only the one with
        // exactly the quoted people; none, or more than one, means no memory.
        if !scope.requiredParticipants.isEmpty {
            let same = found.filter { isSameAudience($0, quoted: scope.requiredParticipants, sources: sources) }
            if same.count != 1 { log("no single thread with exactly the quoted people; not using memory") }
            return same.count == 1 ? same[0] : nil
        }
        if found.count > 1 { log("title matches \(found.count) conversations; not using memory") }
        return found.count == 1 ? found[0] : nil
    }

    /// A shared subject is not a shared audience. Every address in the reply's quote header, minus
    /// the addresses the user sends from (learned from sent mail), must be exactly the thread's
    /// people: not a subset (a reply to part of a group), not a superset. An address memory does
    /// not know is someone else, so it means another audience: otherwise a stranger could copy a
    /// thread's people and subject into their header and have the reply to them draw on that
    /// thread. An own address memory has not learned counts the same way, the safe side. People
    /// are compared by address: a thread also lists its senders' display names, which a header
    /// cannot be matched against.
    private func isSameAudience(_ conversation: MemoryConversation, quoted: Set<String>, sources: [String]) -> Bool {
        let thread = Set(conversation.participants.map(ParticipantNormalizer.normalize).filter { $0.contains("@") })
        let quoted = Set(quoted.map(ParticipantNormalizer.normalize).filter { !$0.isEmpty })
        guard !thread.isEmpty, let own = try? store.ownAddresses(among: quoted, sources: sources) else { return false }
        return quoted.subtracting(own) == thread
    }

    private func scopedHybrid(
        query: String, conversations: [(source: String, conversationKey: String)], topK: Int
    ) -> [MemorySearchResult.Hit] {
        let allowed = Set(conversations.map { $0.source + "\u{1f}" + $0.conversationKey })
        return hybrid(
            query: query, task: .conversationContext, topK: topK,
            vectorFilter: { allowed.contains($0.source + "\u{1f}" + $0.conversationKey) },
            keyword: { try self.store.keywordSearch(query: query, conversations: conversations, limit: topK * 3).map(\.recordID) }
        )
    }

    /// Vector and keyword rankings, fused. The vector side is filtered before scoring, so nothing
    /// outside the filter can be returned; the keyword side is given ids already restricted.
    private func hybrid(
        query: String, task: EmbeddingCore.QueryTask, topK: Int,
        vectorFilter: (FlatVectorIndex.Entry) -> Bool, keyword: () throws -> [String]
    ) -> [MemorySearchResult.Hit] {
        let weight = configuration.index.vectorWeight
        var vectorRanked: [String] = []
        var similarity: [String: Float] = [:]
        let embeddingStarted = Date()
        if weight > 0, !index.isEmpty, let queryVector = try? embedding.embedQuery(query, task: task) {
            let milliseconds = Date().timeIntervalSince(embeddingStarted) * 1000
            updateStatus { $0.queryEmbeddingLatency.record(milliseconds) }
            for (entry, score) in index.search(queryVector, limit: max(topK * 3, 12), where: vectorFilter) {
                if similarity[entry.recordID] == nil { vectorRanked.append(entry.recordID) }
                similarity[entry.recordID] = max(similarity[entry.recordID] ?? -1, score)
            }
        }
        var keywordRanked: [String] = []
        if weight < 1 {
            var seen = Set<String>()
            keywordRanked = ((try? keyword()) ?? []).filter { seen.insert($0).inserted }
        }
        let fused = ReciprocalRankFusion.fuse(vector: vectorRanked, keyword: keywordRanked, vectorWeight: weight)
        var messages: [String: MemoryStore.StoredMessage] = [:]
        for item in fused.prefix(topK * 3) {
            if let message = try? store.message(recordID: item.id) { messages[item.id] = message }
        }
        return fused.compactMap { item -> MemorySearchResult.Hit? in
            guard let message = messages[item.id] else { return nil }  // Deleted since it was indexed.
            let found = (similarity[item.id] != nil, keywordRanked.contains(item.id))
            return MemorySearchResult.Hit(
                recordId: message.recordID, source: message.source, conversationId: message.conversationID,
                conversationTitle: store.conversationName(source: message.source, conversationKey: message.conversationKey).title,
                sender: message.sender, isFromMe: message.isFromMe, timestamp: message.timestamp, subject: message.subject,
                text: message.text, score: item.score, similarity: Double(similarity[item.id] ?? 0),
                via: found.0 && found.1 ? "both" : (found.0 ? "vector" : "keyword")
            )
        }.prefix(topK).map { $0 }
    }

    private func result(
        _ scope: String, _ conversation: MemoryConversation?, _ hits: [MemorySearchResult.Hit], _ started: Date
    ) -> MemorySearchResult {
        let milliseconds = Date().timeIntervalSince(started) * 1000
        updateStatus { $0.searchLatency.record(milliseconds) }
        return MemorySearchResult(scope: scope, conversation: conversation, elapsedMs: milliseconds, hits: hits)
    }

    // MARK: - Status and logging

    private func updateStatus(_ change: (inout MemoryEngineStatus) -> Void) {
        statusLock.lock()
        var status = statusValue
        change(&status)
        let changed = status != statusValue
        statusValue = status
        statusLock.unlock()
        if changed { onStatusChange?(status) }
    }

    private func log(_ message: String) {
        CotabbyLogger.app.info("Memory: \(message)", metadata: ["category": .string("memory")])
    }
}
