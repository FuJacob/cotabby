import Combine
import Foundation
import Logging

/// Owns the user's typing history: its preferences, the encrypted archive, recording new typing, and
/// the search structures that turn history into prompt examples and phrase shortcuts.
///
/// Ownership: built once by `CotabbyAppEnvironment` and kept for the app's lifetime. The suggestion
/// coordinator and the phrase engine read it through `SuggestionHistoryProviding`; the Context
/// settings pane observes it directly (`@ObservedObject`) for its toggles, counts, Import, and
/// Delete All. Its preferences live here rather than in `SuggestionSettingsModel` because they only
/// matter to this subsystem, and keeping them together keeps Delete All and the recording gate in
/// one place.
///
/// Concurrency: everything mutable is `@MainActor`. Expensive work runs on detached tasks against
/// value copies: decrypting and encrypting the archive (`TypingHistoryVault`) and building the index
/// and phrase table. Each rebuild carries a generation number so a slow, older build can never
/// replace a newer one.
@MainActor
final class TypingHistoryStore: ObservableObject, SuggestionHistoryProviding {
    enum Status: Equatable {
        case loading
        case ready
        /// The archive exists but could not be opened. Recording and import stay off so the
        /// unreadable file is never overwritten with a smaller one.
        case unavailable(String)
    }

    @Published private(set) var preferences: TypingHistoryPreferences
    @Published private(set) var recordCount = 0
    /// Entries per app, for the Apps settings list and its per-app Delete.
    @Published private(set) var recordCountsByApp: [String: Int] = [:]
    @Published private(set) var status: Status = .loading
    @Published private(set) var isImporting = false
    @Published private(set) var lastImportMessage: String?

    /// Oldest records are dropped past this many. Retrieval and the phrase table stay small enough
    /// to rebuild in a second or two, and very old writing says little about how the user writes now.
    static let maximumRecords = 20_000
    /// Fields with less text than this are not worth keeping ("ok", a search term).
    static let minimumRecordedCharacters = 20

    private let vault: TypingHistoryVault
    /// Every write and delete goes through this so a deletion can never be undone by a save that
    /// was already running (see `TypingHistoryWriter`).
    private let writer: TypingHistoryWriter
    /// Bumped by Delete All. Work that started before a deletion (a load, an import, a save)
    /// compares its captured value and discards its result instead of restoring deleted history.
    private var persistenceGeneration = 0
    /// Numbers each captured save so an older snapshot can never overwrite a newer one.
    private var saveSequence = 0
    private let userDefaults: UserDefaults
    private var records: [TypingHistoryRecord] = []
    private var index: TypingHistoryIndex?
    private var phrases: TypingHistoryPhrasePredictor?
    private var rebuildGeneration = 0
    private var saveTask: Task<Void, Never>?
    private var activeRecording: ActiveRecording?
    /// Recently finished fields, by field key. When the user returns to one (or Accessibility
    /// briefly reported it unsupported), recording resumes into the same record instead of
    /// starting a duplicate of the same text.
    private var recentRecordings: [String: ActiveRecording] = [:]
    private static let maximumRecentRecordings = 64
    /// How much of a field's opening must match for a returning field to count as the same document.
    private static let sameDocumentOpeningLength = 40
    private var exampleCache: (key: String, examples: [String])?

    /// The field being typed in right now. Its raw text is kept here and only scrubbed and copied
    /// into `records` when saving or when focus moves on, so recording costs a string comparison
    /// per keystroke rather than a regex pass over the whole field.
    private struct ActiveRecording {
        let fieldKey: String
        let recordID: UUID
        let bundleIdentifier: String
        let domain: String?
        let createdAt: Date
        var rawText: String
        /// Characters before the caret in `rawText` at the latest capture.
        var rawTypedLength: Int
    }

    private enum DefaultsKey {
        static let isUsingHistory = "cotabbyTypingHistoryEnabled"
        static let isRecording = "cotabbyTypingHistoryRecordingEnabled"
        static let excludedBundleIdentifiers = "cotabbyTypingHistoryExcludedApps"
    }

    init(vault: TypingHistoryVault = .standard(), userDefaults: UserDefaults = .standard, loadsArchive: Bool = true) {
        self.vault = vault
        self.writer = TypingHistoryWriter(vault: vault)
        self.userDefaults = userDefaults
        preferences = TypingHistoryPreferences(
            isUsingHistory: userDefaults.object(forKey: DefaultsKey.isUsingHistory) as? Bool
                ?? TypingHistoryPreferences.defaults.isUsingHistory,
            isRecording: userDefaults.object(forKey: DefaultsKey.isRecording) as? Bool
                ?? TypingHistoryPreferences.defaults.isRecording,
            excludedBundleIdentifiers: userDefaults.stringArray(forKey: DefaultsKey.excludedBundleIdentifiers) ?? []
        )
        if loadsArchive {
            Task { await loadArchive() }
        } else {
            status = .ready
        }
    }

    // MARK: - Preferences

    func setUsingHistory(_ enabled: Bool) {
        guard preferences.isUsingHistory != enabled else { return }
        preferences.isUsingHistory = enabled
        userDefaults.set(enabled, forKey: DefaultsKey.isUsingHistory)
        exampleCache = nil
    }

    func setRecording(_ enabled: Bool) {
        guard preferences.isRecording != enabled else { return }
        preferences.isRecording = enabled
        userDefaults.set(enabled, forKey: DefaultsKey.isRecording)
        if !enabled { finishActiveRecording() }
    }

    func setExcluded(_ bundleIdentifier: String, excluded: Bool) {
        var identifiers = preferences.excludedBundleIdentifiers.filter { $0 != bundleIdentifier }
        if excluded { identifiers.append(bundleIdentifier) }
        identifiers.sort()
        guard identifiers != preferences.excludedBundleIdentifiers else { return }
        preferences.excludedBundleIdentifiers = identifiers
        userDefaults.set(identifiers, forKey: DefaultsKey.excludedBundleIdentifiers)
        if excluded, activeRecording?.bundleIdentifier == bundleIdentifier {
            // Excluding an app mid-field discards that field's unsaved text instead of keeping it.
            activeRecording = nil
            recentRecordings = recentRecordings.filter { $0.value.bundleIdentifier != bundleIdentifier }
        }
    }

    // MARK: - Loading, saving, rebuilding

    func loadArchive() async {
        let vault = vault
        let generation = persistenceGeneration
        do {
            let loaded = try await Task.detached(priority: .utility) { try vault.load() }.value
            // Delete All ran while the archive was decrypting: the loaded records are gone now.
            guard generation == persistenceGeneration else { return }
            records = loaded
            refreshCounts()
            status = .ready
            rebuildSearchStructures()
        } catch {
            status = .unavailable("Typing history couldn't be opened, so it's paused to avoid overwriting it.")
            CotabbyLogger.app.error("Typing history archive could not be loaded: \(error)")
        }
    }

    /// Writes immediately, on the calling (main) thread. Used at termination, when there is no time
    /// left for a debounced background save.
    func flush() {
        guard status == .ready else { return }
        saveTask?.cancel()
        materializeActiveRecording()
        saveSequence += 1
        do {
            try writer.save(records, generation: persistenceGeneration, sequence: saveSequence)
        } catch {
            CotabbyLogger.app.error("Typing history could not be saved: \(error)")
        }
    }

    private func scheduleSave() {
        guard status == .ready else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.materializeActiveRecording()
            self.saveSequence += 1
            let snapshot = self.records
            let writer = self.writer
            let generation = self.persistenceGeneration
            let sequence = self.saveSequence
            do {
                try await Task.detached(priority: .utility) {
                    try writer.save(snapshot, generation: generation, sequence: sequence)
                }.value
            } catch {
                CotabbyLogger.app.error("Typing history could not be saved: \(error)")
            }
        }
    }

    /// Rebuilds the index and phrase table off the main actor from a copy of the records. The field
    /// being typed in is left out so the user's unfinished draft never becomes its own example.
    private func rebuildSearchStructures() {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let activeID = activeRecording?.recordID
        let snapshot = records.filter { $0.id != activeID }
        Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                (TypingHistoryIndex(records: snapshot), TypingHistoryPhrasePredictor(records: snapshot))
            }.value
            guard let self, generation == self.rebuildGeneration else { return }
            self.index = built.0
            self.phrases = built.1
            self.exampleCache = nil
        }
    }

    // MARK: - Recording

    /// Called for every focus snapshot. Cheap unless the field's text changed.
    ///
    /// `isAllowed` carries Cotabby's own gates (globally on, not paused, app not disabled), so
    /// history is only ever recorded where Cotabby itself is active. It is a closure because it
    /// builds a settings snapshot, and this runs on every focus poll: it is only evaluated once
    /// recording is on. Secure fields never reach here as supported, and are checked again below.
    func observe(_ snapshot: FocusSnapshot, isAllowed: () -> Bool) {
        guard status == .ready, preferences.isRecording,
              case .supported = snapshot.capability,
              let input = snapshot.context, !input.isSecure,
              !Self.isTerminal(input),
              !preferences.excludedBundleIdentifiers.contains(input.bundleIdentifier)
        else {
            finishActiveRecording()
            return
        }

        // The focus sequence is left out on purpose: leaving a field and coming back starts a new
        // focus session, but it is the same document and should stay one record.
        let fieldKey = "\(input.bundleIdentifier)|\(input.processIdentifier)|\(input.elementIdentifier)"
        let text = input.precedingText + input.trailingText
        // Unchanged text in the same field is the common case on a 50 ms poll; answer it before
        // building the settings snapshot `isAllowed` needs.
        if activeRecording?.fieldKey == fieldKey, activeRecording?.rawText == text { return }
        guard isAllowed() else {
            finishActiveRecording()
            return
        }

        if activeRecording?.fieldKey != fieldKey {
            finishActiveRecording()
            activeRecording = resumedRecording(fieldKey: fieldKey, text: text, typedLength: input.precedingText.count)
                ?? ActiveRecording(
                    fieldKey: fieldKey,
                    recordID: UUID(),
                    bundleIdentifier: input.bundleIdentifier,
                    domain: SurfaceContextComposer.registrableDomain(from: input.focusedURLString),
                    createdAt: Date(),
                    rawText: text,
                    rawTypedLength: input.precedingText.count
                )
            return
        }
        activeRecording?.rawText = text
        activeRecording?.rawTypedLength = input.precedingText.count
        scheduleSave()
    }

    /// Terminals are never recorded: their text is shell commands and output, where secrets are
    /// common and nothing is the user's prose.
    private static func isTerminal(_ input: FocusedInputSnapshot) -> Bool {
        input.isIntegratedTerminal || AppSurfaceClassifier.classify(bundleIdentifier: input.bundleIdentifier) == .terminal
    }

    /// Continues the record of a recently finished field when the user comes back to it. The text
    /// must still start the same way: Accessibility element identifiers can be reused by a
    /// different field, and resuming into the wrong record would overwrite its text.
    private func resumedRecording(fieldKey: String, text: String, typedLength: Int) -> ActiveRecording? {
        guard var recent = recentRecordings[fieldKey] else { return nil }
        let opening = recent.rawText.prefix(Self.sameDocumentOpeningLength)
        guard !opening.isEmpty, text.hasPrefix(opening) || recent.rawText.hasPrefix(text.prefix(Self.sameDocumentOpeningLength))
        else { return nil }
        recent.rawText = text
        recent.rawTypedLength = typedLength
        return recent
    }

    /// Commits the active field to `records` and makes it searchable. Called when focus moves to
    /// another field, recording stops, or the app is no longer eligible.
    private func finishActiveRecording() {
        guard activeRecording != nil else { return }
        let changed = materializeActiveRecording()
        if let finished = activeRecording {
            recentRecordings[finished.fieldKey] = finished
            if recentRecordings.count > Self.maximumRecentRecordings, let oldest = recentRecordings.values
                .min(by: { $0.createdAt < $1.createdAt }) {
                recentRecordings[oldest.fieldKey] = nil
            }
        }
        activeRecording = nil
        if changed {
            scheduleSave()
            rebuildSearchStructures()
        }
    }

    /// Copies the active field's scrubbed text into `records`. Returns whether anything changed.
    @discardableResult
    private func materializeActiveRecording() -> Bool {
        guard let active = activeRecording else { return false }
        let split = active.rawText.index(active.rawText.startIndex, offsetBy: min(active.rawTypedLength, active.rawText.count))
        let (text, typedLength) = TypingHistoryScrubber.scrub(
            before: String(active.rawText[..<split]), after: String(active.rawText[split...])
        )
        let existingIndex = records.firstIndex { $0.id == active.recordID }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumRecordedCharacters else {
            // The user cleared the field down to nothing worth keeping.
            if let existingIndex {
                records.remove(at: existingIndex)
                refreshCounts()
                return true
            }
            return false
        }
        if let existingIndex {
            guard records[existingIndex].text != text || records[existingIndex].typedLength != typedLength else {
                return false
            }
            records[existingIndex].text = text
            records[existingIndex].typedLength = typedLength
            records[existingIndex].updatedAt = Date()
        } else {
            records.append(TypingHistoryRecord(
                id: active.recordID, bundleIdentifier: active.bundleIdentifier, domain: active.domain,
                createdAt: active.createdAt, updatedAt: Date(), text: text, source: .recorded,
                typedLength: typedLength
            ))
            trimToCapacity()
        }
        refreshCounts()
        return true
    }

    private func trimToCapacity() {
        guard records.count > Self.maximumRecords else { return }
        records.sort { $0.updatedAt < $1.updatedAt }
        records.removeFirst(records.count - Self.maximumRecords)
    }

    // MARK: - Import and deletion

    /// Imports a Cotypist `user_inputs.json` export. Entries whose text is already in history are
    /// skipped, so importing the same file twice adds nothing.
    func importCotypistExport(from url: URL) async {
        guard status == .ready, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let generation = persistenceGeneration
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try CotypistExportImporter.records(fromExport: Data(contentsOf: url))
            }.value
            // Delete All ran while the file was being read; adding the import now would partly undo it.
            guard generation == persistenceGeneration else {
                lastImportMessage = "Import cancelled because typing history was deleted."
                return
            }
            let knownTexts = Set(records.map(\.text))
            let fresh = imported.filter { !knownTexts.contains($0.text) }
            records.append(contentsOf: fresh)
            trimToCapacity()
            refreshCounts()
            lastImportMessage = "Imported \(fresh.count) entries"
                + (imported.count > fresh.count ? " (\(imported.count - fresh.count) were already in your history)." : ".")
            scheduleSave()
            rebuildSearchStructures()
        } catch {
            lastImportMessage = (error as? LocalizedError)?.errorDescription ?? "Import failed: \(error.localizedDescription)"
        }
    }

    /// Removes one app's records, keeping everything else. The field being typed in that app is
    /// dropped too, so it is not written back a few seconds later.
    func deleteRecords(forBundleIdentifier bundleIdentifier: String) {
        if activeRecording?.bundleIdentifier == bundleIdentifier { activeRecording = nil }
        recentRecordings = recentRecordings.filter { $0.value.bundleIdentifier != bundleIdentifier }
        let remaining = records.filter { $0.bundleIdentifier != bundleIdentifier }
        guard remaining.count != records.count else { return }
        records = remaining
        refreshCounts()
        scheduleSave()
        rebuildSearchStructures()
    }

    private func refreshCounts() {
        recordCount = records.count
        recordCountsByApp = Dictionary(grouping: records, by: \.bundleIdentifier).mapValues(\.count)
    }

    /// Removes every record, the encrypted file, and its Keychain key.
    func deleteAll() {
        saveTask?.cancel()
        persistenceGeneration += 1
        activeRecording = nil
        recentRecordings = [:]
        records = []
        refreshCounts()
        index = nil
        phrases = nil
        exampleCache = nil
        rebuildGeneration += 1
        lastImportMessage = nil
        do {
            // Waits for any save already writing, then deletes; saves captured earlier are dropped.
            try writer.destroy(generation: persistenceGeneration)
            status = .ready
        } catch {
            CotabbyLogger.app.error("Typing history could not be deleted: \(error)")
        }
    }

    // MARK: - SuggestionHistoryProviding

    func historyExamples(for context: FocusedInputContext, engine: SuggestionEngineKind) -> [String] {
        guard preferences.isUsingHistory, engine != .openAICompatible, let index else { return [] }
        let stableText = TypingHistoryQuery.stableText(from: context.precedingText)
        // The window title (an email subject, a document name) is the most stable topical signal a
        // field has, so it joins the query even before the first full block of words is typed.
        let queryText = [stableText, context.windowTitle ?? ""].joined(separator: " ")
        let cacheKey = "\(context.focusedInputIdentityKey)|\(queryText)"
        if let exampleCache, exampleCache.key == cacheKey { return exampleCache.examples }

        let examples = index.examples(for: TypingHistoryQuery(
            text: queryText,
            bundleIdentifier: context.bundleIdentifier,
            domain: SurfaceContextComposer.registrableDomain(from: context.focusedURLString),
            currentFieldText: context.precedingText
        ))
        exampleCache = (cacheKey, examples)
        return examples
    }

    func phraseContinuation(for request: SuggestionRequest, engine: SuggestionEngineKind) -> String? {
        guard preferences.isUsingHistory, engine != .openAICompatible, let phrases else { return nil }
        // Text after the caret on the same line would be pushed along by an inserted phrase; leave
        // those mid-line positions to the model, which sees the trailing text.
        let restOfLine = request.context.trailingText.prefix { !$0.isNewline }
        guard restOfLine.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return phrases.continuation(
            after: request.context.precedingText,
            limits: TypingHistoryPhrasePredictor.Limits(
                maxWords: request.wordRange?.highWords ?? 8,
                allowsNewlines: request.isMultiLineEnabled
            )
        )
    }
}
