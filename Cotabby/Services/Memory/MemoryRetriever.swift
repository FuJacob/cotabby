import Foundation
import Logging

/// File overview:
/// Gives the suggestion pipeline the earlier messages of the conversation being written in, from
/// the local memory engine, without ever making a suggestion wait for them.
///
/// How a request gets memory:
/// 1. `ConversationScopeResolver` turns the focused app and window into a scope (the chat name or
///    mail subject, within the app's enabled memory sources), and builds a stable query.
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

    static let maximumCacheEntries = 64

    init(engine: @escaping @MainActor () -> MemoryEngine?) {
        self.engine = engine
    }

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
            updateSources([])
            return
        }
        updateSources(await Task.detached(priority: .utility) { engine.sources() }.value)
    }

    // MARK: - SuggestionMemoryProviding

    func memorySnippets(for context: FocusedInputContext, engine: SuggestionEngineKind) -> [String] {
        // Memory is private history from this Mac: never part of a request the endpoint could send.
        guard engine != .openAICompatible, !context.isSecure, self.engine() != nil,
              let scope = ConversationScopeResolver.scope(
                  bundleIdentifier: context.bundleIdentifier,
                  conversationTitle: context.windowTitle,
                  trailingText: context.trailingText,
                  sourcesByBundle: sourcesByBundle
              ) else { return [] }

        let key = CacheKey(scope: scope, query: ConversationScopeResolver.query(precedingText: context.precedingText, scope: scope))
        lastRequested = key
        if let cached = cache[key] { return cached }
        startLookup(key)
        return latestByScope[scope] ?? []
    }

    private func startLookup(_ key: CacheKey) {
        guard inFlight != key, let engine = engine() else { return }
        inFlight = key
        let started = Date()
        var scope = MemoryEngine.Scope()
        scope.title = key.scope.title
        scope.sources = key.scope.sources
        scope.requiredParticipants = key.scope.requiredParticipants
        Task { [weak self] in
            let result: MemorySearchResult? = await Task.detached(priority: .userInitiated) {
                engine.search(query: key.query, scope: scope)
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
            if self.cache.count >= Self.maximumCacheEntries { self.cache.removeAll() }
            self.cache[key] = lines
            let changed = self.latestByScope[key.scope] != lines
            self.latestByScope[key.scope] = lines
            // Offer a suggestion that uses it only if it is new for the conversation still in focus.
            if changed, !lines.isEmpty, self.lastRequested?.scope == key.scope {
                self.onMemoryReady?()
            }
        }
    }
}
