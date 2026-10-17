import Foundation
import Logging

/// File overview:
/// Gives the suggestion pipeline the earlier messages of the conversation being written in, from
/// the local memory engine, without ever making a suggestion wait for them.
///
/// How a request gets memory:
/// 1. `ConversationScopeResolver` turns the focused app and window into a scope (the chat name,
///    within the app's enabled memory sources; mail gets none), and builds a stable query.
/// 2. If the cache already holds the lines for that scope and query, they are returned. Otherwise
///    the cached lines for the same conversation (an earlier query) are returned, or nothing, and a
///    lookup starts in the background.
/// 3. When the lookup lands for the conversation still in focus, `onMemoryReady` lets the
///    coordinator offer a suggestion that uses it.
///
/// Gates, all checked here so the coordinator stays unaware of them: memory switched on and its
/// engine running, a suggestion engine other than the endpoint, and a non-secure field. Built once
/// by `CotabbyAppEnvironment`.
@MainActor
final class MemoryRetriever: SuggestionMemoryProviding {
    var onMemoryReady: (@MainActor () -> Void)?

    private let engine: @MainActor () -> MemoryEngine?

    /// Enabled memory sources per app bundle id, from the engine's source list.
    private(set) var sourcesByBundle: [String: [String]] = [:]

    private struct CacheKey: Hashable {
        let scope: ConversationScope
        let query: String
    }

    private var cache: [CacheKey: [String]] = [:]
    /// The newest lines per conversation, served while a lookup for a newer query is in flight.
    private var latestByScope: [ConversationScope: [String]] = [:]
    private var inFlight: CacheKey?
    private var lastRequested: CacheKey?
    /// The engine (`MemoryEngine.instanceID`) and its `dataGeneration` the caches were filled
    /// under. When either changes (something was deleted, excluded or switched off, or memory
    /// restarted), the caches go, and a lookup started before lands nowhere: a deleted message is
    /// never kept or served from here. Both the check and every cache write happen inside the
    /// engine's `withDataGeneration`, so a removal cannot begin between them.
    private var cachedEngine: UUID?
    private var cachedGeneration: UInt64 = 0

    static let maximumCacheEntries = 64

    /// The search a lookup runs, off the main actor (the engine's own; tests hold it back).
    typealias Search = @Sendable (MemoryEngine, String, MemoryEngine.Scope) -> MemorySearchResult?
    private let search: Search

    init(
        engine: @escaping @MainActor () -> MemoryEngine?,
        search: @escaping Search = { engine, query, scope in engine.search(query: query, scope: scope) }
    ) {
        self.engine = engine
        self.search = search
    }

    // All stored state is safe to release from any thread (Combine publishers, closures, task
    // handles, values). A nonisolated deinit keeps teardown off the back-deployment main-actor
    // executor shim, which over-releases on macOS 26 (same as `SuggestionSettingsModel`).
    nonisolated deinit {}

    /// Replaces the app -> sources map: only enabled sources serve memory.
    func updateSources(_ sources: [MemorySource]) {
        var map: [String: [String]] = [:]
        for source in sources where source.enabled {
            for bundle in source.appBundleIds {
                map[bundle, default: []].append(source.id)
            }
        }
        if map != sourcesByBundle {
            sourcesByBundle = map
            cache.removeAll()
            latestByScope.removeAll()
        }
    }

    /// Reads the source list from the engine and updates the map. Called when memory starts and
    /// after source changes.
    func reloadSources() async {
        guard let engine = engine() else {
            dropCaches()
            updateSources([])
            return
        }
        updateSources(await Task.detached(priority: .utility) { engine.sources() }.value)
    }

    // MARK: - SuggestionMemoryProviding

    func memorySnippets(for context: FocusedInputContext, engine: SuggestionEngineKind) -> [String] {
        // Memory is private history from this Mac: never part of a request the endpoint could send.
        guard engine != .openAICompatible, !context.isSecure else { return [] }
        guard let memory = self.engine() else {
            // Memory off: what it found while on is not kept for when it comes back.
            dropCaches()
            return []
        }
        guard let scope = ConversationScopeResolver.scope(
                  bundleIdentifier: context.bundleIdentifier,
                  conversationTitle: context.windowTitle,
                  sourcesByBundle: sourcesByBundle
              ) else { return [] }

        let key = CacheKey(scope: scope, query: ConversationScopeResolver.query(precedingText: context.precedingText, scope: scope))
        lastRequested = key
        let (cached, latest): ([String]?, [String]?) = memory.withDataGeneration { generation in
            dropCachesIfStale(memory, generation: generation)
            return (cache[key], latestByScope[scope])
        }
        if let cached { return cached }
        startLookup(key, engine: memory)
        return latest ?? []
    }

    /// Empties the caches when the engine was replaced or its stored data changed since they were
    /// filled. Called inside the engine's `withDataGeneration`.
    private func dropCachesIfStale(_ engine: MemoryEngine, generation: UInt64) {
        guard engine.instanceID != cachedEngine || generation != cachedGeneration else { return }
        dropCaches()
        cachedEngine = engine.instanceID
        cachedGeneration = generation
    }

    private func dropCaches() {
        cache.removeAll()
        latestByScope.removeAll()
        inFlight = nil
        cachedEngine = nil
    }

    private func startLookup(_ key: CacheKey, engine: MemoryEngine) {
        guard inFlight != key else { return }
        inFlight = key
        // Read before the search starts: a removal that begins after this moves it, and the
        // search's result is then dropped when it lands.
        let generation = engine.dataGeneration
        let search = search
        let started = Date()
        var scope = MemoryEngine.Scope()
        scope.title = key.scope.title
        scope.sources = key.scope.sources
        Task { [weak self] in
            let result: MemorySearchResult? = await Task.detached(priority: .userInitiated) {
                search(engine, key.query, scope)
            }.value
            guard let self else { return }
            if self.inFlight == key { self.inFlight = nil }
            let lines = MemorySnippetFormatter.lines((result?.hits ?? []).map {
                MemorySnippetFormatter.Message(
                    sender: $0.sender, isFromMe: $0.isFromMe,
                    timestamp: Date(timeIntervalSince1970: $0.timestamp), text: $0.text
                )
            })
            CotabbyLogger.suggestion.debug("Memory lookup", metadata: [
                "stage": "memory",
                "memory_ms": .stringConvertible(Int(Date().timeIntervalSince(started) * 1000)),
                // The engine's own time; the rest of memory_ms is thread hops and waiting for the
                // main actor.
                "memory_engine_ms": .stringConvertible(Int(result?.elapsedMs ?? -1)),
                "memory_hits": .stringConvertible(result?.hits.count ?? -1),
                "memory_scope": .string(result?.scope ?? "failed")
            ])
            guard result != nil else { return }
            // Kept only if nothing was removed since the search started, under this engine, and
            // with the caches still the ones filled under that generation; checked and written
            // while no removal can begin.
            let changed: Bool? = engine.withDataGeneration { current in
                guard current == generation, self.cachedEngine == engine.instanceID,
                      self.cachedGeneration == generation else { return nil }
                if self.cache.count >= Self.maximumCacheEntries { self.cache.removeAll() }
                self.cache[key] = lines
                let changed = self.latestByScope[key.scope] != lines
                self.latestByScope[key.scope] = lines
                return changed
            }
            // Offer a suggestion that uses it only if it is new for the conversation still in focus.
            if changed == true, !lines.isEmpty, self.lastRequested?.scope == key.scope {
                self.onMemoryReady?()
            }
        }
    }
}
