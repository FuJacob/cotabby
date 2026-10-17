import Combine
import Foundation

/// File overview:
/// The Memory settings pane's view of conversation memory: its settings, sources and playground,
/// plus the actions the pane offers (sync, forget, re-index, privacy, search).
///
/// Why separate from `MemoryEngineController`: the controller owns the engine's lifecycle and must
/// work with no window open; this model holds what a person looks at, and only refreshes while the
/// pane is visible (`beginObserving` / `endObserving`). Every engine call runs off the main actor,
/// since the engine's work is synchronous and may touch disk. Built once by `CotabbyAppEnvironment`.
@MainActor
final class MemoryControlModel: ObservableObject {
    @Published private(set) var configuration: MemoryConfiguration?
    @Published private(set) var sources: [MemorySource] = []
    @Published private(set) var lastError: String?
    @Published private(set) var playgroundResult: MemorySearchResult?
    @Published private(set) var isSearching = false
    /// Recently active conversations of one source, for the Playground's picker.
    @Published private(set) var playgroundConversations: [MemoryConversation] = []

    let controller: MemoryEngineController
    /// Reads the sources on this Mac; the pane observes it directly too.
    let historySync: MemoryHistorySync
    private var observers = 0
    private var pollTask: Task<Void, Never>?
    /// Counts Playground searches; only the newest one's result is shown.
    private var searchGeneration = 0

    init(controller: MemoryEngineController, historySync: MemoryHistorySync) {
        self.controller = controller
        self.historySync = historySync
    }

    // All stored state is safe to release from any thread (Combine publishers, closures, task
    // handles, values). A nonisolated deinit keeps teardown off the back-deployment main-actor
    // executor shim, which over-releases on macOS 26 (same as `SuggestionSettingsModel`).
    nonisolated deinit {}

    private var engine: MemoryEngine? { controller.engine }

    // MARK: - Observation

    func beginObserving() {
        observers += 1
        guard observers == 1 else { return }
        // The loop body lives in `pollOnce()`: a typed Task with a short closure type-checks quickly
        // on older compilers, and `self` is only held while a refresh runs, not across the sleep.
        pollTask = Task<Void, Never> { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// One poll: refreshes, then returns the wait before the next one, in nanoseconds.
    private func pollOnce() async -> UInt64 {
        await refresh()
        // Counts change while indexing; refresh faster then.
        let seconds: UInt64 = controller.status.isIndexing ? 2 : 5
        return seconds * 1_000_000_000
    }

    func endObserving() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reloads the settings and the sources (with their stored counts).
    func refresh() async {
        guard let engine else {
            configuration = nil
            sources = []
            return
        }
        let (configuration, sources) = await Task.detached(priority: .userInitiated) {
            (engine.configuration, engine.sources())
        }.value
        if self.configuration != configuration { self.configuration = configuration }
        if self.sources != sources { self.sources = sources }
    }

    // MARK: - Actions

    func setSourceEnabled(_ id: String, enabled: Bool) {
        change({ $0.sources[id, default: MemorySourceSettings(enabled: false)].enabled = enabled }, then: {
            if enabled {
                self.historySync.refreshReadiness()
                await self.sync(id)
            }
        })
    }

    /// Pointing a source at another folder makes the engine forget what it read from the old one;
    /// a sync of the old folder still running is stopped first, so none of it is stored afterwards.
    func setSourceOption(_ id: String, key: String, value: String) {
        let edit: @Sendable (MemoryEngine) throws -> Void = { engine in
            try engine.updateConfiguration { $0.sources[id, default: MemorySourceSettings(enabled: false)].options[key] = value }
        }
        let changesFolder = key == MemoryEngine.folderOption
        perform(edit, before: {
            if changesFolder { await self.historySync.cancelSync(id) }
        }, then: {
            self.historySync.refreshReadiness()
        })
    }

    /// Whether answers may quote facts from this source (Settings → Memory → Sources).
    func setAnswerSource(_ id: String, enabled: Bool) {
        change { $0.sources[id, default: MemorySourceSettings(enabled: false)].answerSource = enabled }
    }

    func updateIndexSettings(_ settings: MemoryIndexSettings) {
        let settings = settings.clamped()
        change { $0.index = settings }
    }

    func updatePrivacy(_ privacy: MemoryPrivacySettings) {
        change { $0.privacy = privacy }
    }

    /// Adds a conversation to Privacy's never-remember list (its stored messages are purged and
    /// later syncs skip it), then reloads the Playground's list without it.
    func neverRemember(_ conversation: MemoryConversation) {
        let id = conversation.conversationId
        change({
            if !$0.privacy.excludedConversations.contains(id) { $0.privacy.excludedConversations.append(id) }
        }, then: {
            self.loadConversations(source: conversation.source)
        })
    }

    func updateAnswers(_ answers: MemoryAnswerSettings) {
        change { $0.answers = answers }
    }

    /// Syncs one source, or every enabled one.
    func sync(_ id: String? = nil) async {
        if let id {
            await historySync.sync(id)
        } else {
            for source in sources where source.enabled {
                await historySync.sync(source.id)
            }
        }
        await refresh()
    }

    /// Deletes what one source stored, after stopping its sync: a page read before the delete
    /// would otherwise be stored again, with a cursor that skips everything before it.
    func forget(_ id: String) {
        perform({ try $0.forget(source: id) }, before: { await self.historySync.cancelSync(id) })
    }

    /// Embeds every message again (after a model or settings change, or to repair the index).
    func rebuildIndex() {
        perform { try $0.rebuildIndex() }
    }

    func deleteAllMemory() {
        perform({ try $0.deleteEverything() }, before: { await self.historySync.cancelSync() })
    }

    private func change(_ edit: @escaping @Sendable (inout MemoryConfiguration) -> Void, then: (@MainActor () async -> Void)? = nil) {
        perform({ try $0.updateConfiguration(edit) }, then: then)
    }

    private func perform(
        _ work: @escaping @Sendable (MemoryEngine) throws -> Void,
        before: (@MainActor () async -> Void)? = nil,
        then: (@MainActor () async -> Void)? = nil
    ) {
        guard let engine else { return }
        Task {
            await before?()
            do {
                try await Task.detached(priority: .userInitiated) { try work(engine) }.value
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            await then?()
            await refresh()
        }
    }

    // MARK: - Playground

    func loadConversations(source: String) {
        guard let engine else { return }
        Task {
            playgroundConversations = await Task.detached(priority: .userInitiated) {
                engine.recentConversations(sources: [source], limit: 300)
            }.value
        }
    }

    /// Searches one exact conversation the way a suggestion written there would.
    func search(query: String, conversation: MemoryConversation) {
        var scope = MemoryEngine.Scope()
        scope.conversation = (conversation.source, conversation.conversationId)
        runSearch(query, scope)
    }

    /// Searches every enabled source (exploring only; suggestions never search this widely).
    func searchEverything(query: String, sources: [String]) {
        var scope = MemoryEngine.Scope()
        scope.global = true
        scope.sources = sources
        runSearch(query, scope)
    }

    /// What an answer to `question` would draw on, from the answer sources (the Answers section's
    /// "Find Facts"; the result shows in the Playground).
    func searchAnswers(question: String) {
        guard let engine else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let answerSources = sources.filter { $0.enabled && $0.isAnswerSource }.map(\.id)
        isSearching = true
        // Shares the Playground's search generation: only the newest search, of either kind, may
        // show its result or end the spinner.
        searchGeneration += 1
        let generation = searchGeneration
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                engine.answerSearch(question: trimmed, sources: answerSources, currentConversation: nil, excludingRecordIDs: [])
            }.value
            guard generation == searchGeneration else { return }
            playgroundResult = result
            isSearching = false
        }
    }

    private func runSearch(_ query: String, _ scope: MemoryEngine.Scope) {
        guard let engine else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchGeneration += 1
            playgroundResult = nil
            isSearching = false
            return
        }
        isSearching = true
        searchGeneration += 1
        let generation = searchGeneration
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                engine.search(query: trimmed, scope: scope)
            }.value
            // A slower earlier search must not replace a newer one's result (or end its spinner).
            guard generation == searchGeneration else { return }
            playgroundResult = result
            isSearching = false
        }
    }
}
