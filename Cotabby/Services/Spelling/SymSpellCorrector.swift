import Foundation
import Logging

/// File overview:
/// Owns Cotabby's language-specific `SymSpell` indexes and exposes synchronous correction lookups
/// for the prediction gate. Index construction is expensive, so dictionaries load on a background
/// queue only when needed. Until a requested language is ready, lookup returns nil and the caller
/// falls back to `NSSpellChecker`.
///
/// `nonisolated` + `@unchecked Sendable` (mirroring `LlamaRuntimeCore`/`JSONLFileWriter`) because the
/// builds run off the main actor while `bestCorrection` is called from it. The lock protects the
/// index cache, whose per-language load state and LRU order live in `BoundedLoadCache`. Each
/// `SymSpell` becomes immutable before entering the cache, so readers can safely query a retained
/// instance after releasing the lock.
nonisolated final class SymSpellCorrector: @unchecked Sendable {
    /// Both indexes built from one dictionary, published together so a language is never ready
    /// for corrections but not for completions.
    private struct Indexes {
        let symSpell: SymSpell
        let prefixes: WordPrefixIndex
    }

    typealias ResourceLoader = @Sendable (SpellingDictionaryLanguage) -> String?

    private let lock = NSLock()
    private let maxEditDistance: Int
    private let prefixLength: Int
    private let resourceLoader: ResourceLoader
    /// Guarded by `lock`.
    private var indexes: BoundedLoadCache<SpellingDictionaryLanguage, Indexes>

    /// `preloadLanguage` preserves the existing fast English startup by default. Production may
    /// pass another sole-enabled language, or nil when the user disabled every bundled dictionary.
    init(
        maxEditDistance: Int = 2,
        prefixLength: Int = 7,
        cacheLimit: Int = 2,
        preloadLanguage: SpellingDictionaryLanguage? = .english,
        resourceLoader: ResourceLoader? = nil
    ) {
        self.maxEditDistance = maxEditDistance
        self.prefixLength = prefixLength
        self.indexes = BoundedLoadCache(limit: cacheLimit)
        self.resourceLoader = resourceLoader ?? Self.bundledContents(for:)

        if let preloadLanguage {
            _ = indexesOrRequestLoad(for: preloadLanguage)
        }
    }

    /// The best single-word correction for `word`, recased to match it, or nil when the index is not
    /// ready yet, the word is in the dictionary, or nothing is within edit distance. The lookup is
    /// case-insensitive: the dictionary is lowercase, and `TypoCaseTransfer` reapplies the typo's case.
    func bestCorrection(
        for word: String,
        language: SpellingDictionaryLanguage = .english
    ) -> String? {
        guard let symSpell = indexesOrRequestLoad(for: language)?.symSpell else {
            return nil
        }

        // Case conversion follows the dictionary's language: Turkish "I" lowercases to "ı", not "i".
        let locale = language.caseLocale
        let lowered = word.lowercased(with: locale)
        guard let suggestion = symSpell.bestSuggestion(for: lowered),
              suggestion.distance > 0,
              suggestion.term.lowercased(with: locale) != lowered else {
            return nil
        }
        return TypoCaseTransfer.applying(caseOf: word, to: suggestion.term, locale: locale)
    }

    /// Returns no candidates while the language is cold. Index construction shares the existing
    /// background load, and the immutable value is retained outside the lock for fast lookups.
    func completionCandidates(for prefix: String, language: SpellingDictionaryLanguage) -> [WordPrefixIndex.Candidate] {
        indexesOrRequestLoad(for: language)?.prefixes.candidates(for: prefix) ?? []
    }

    /// Test seam: synchronously publishes a small in-memory dictionary without touching the bundle.
    func loadForTesting(
        contents: String,
        language: SpellingDictionaryLanguage = .english
    ) {
        let built = buildIndexes(contents: contents, language: language)
        lock.lock()
        indexes.publish(built, for: language)
        lock.unlock()
    }

    /// Test-only visibility into the bounded cache. The sorted result avoids exposing LRU order.
    var cachedLanguagesForTesting: [SpellingDictionaryLanguage] {
        lock.lock()
        let languages = indexes.readyKeys.sorted { $0.rawValue < $1.rawValue }
        lock.unlock()
        return languages
    }

    /// Returns the language's indexes when they are ready. A cold language starts its background
    /// load (once) and returns nil, so the caller falls back for now.
    private func indexesOrRequestLoad(for language: SpellingDictionaryLanguage) -> Indexes? {
        lock.lock()
        let lookup = indexes.lookup(language)
        lock.unlock()

        switch lookup {
        case .ready(let ready):
            return ready
        case .startLoad:
            loadInBackground(language)
            return nil
        case .loading:
            return nil
        }
    }

    private func loadInBackground(_ language: SpellingDictionaryLanguage) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let contents = resourceLoader(language) else {
                lock.lock()
                indexes.loadFailed(for: language)
                lock.unlock()
                CotabbyLogger.app.error(
                    "SymSpell dictionary resource \(language.resourceName).txt not found in bundle"
                )
                return
            }

            let built = buildIndexes(contents: contents, language: language)
            lock.lock()
            indexes.publish(built, for: language)
            lock.unlock()
            CotabbyLogger.app.info(
                "SymSpell loaded \(built.symSpell.wordCount) \(language.displayName) words for correction"
            )
        }
    }

    /// The one build sequence for both the background load and the test seam: the dictionary is
    /// lowercased in its own locale before either index reads it, so the two can never disagree
    /// on case.
    private func buildIndexes(contents: String, language: SpellingDictionaryLanguage) -> Indexes {
        let normalized = SpellingDictionaryCaseNormalizer.lowercased(contents, locale: language.caseLocale)
        let symSpell = makeEmptyIndex()
        symSpell.loadDictionary(contents: normalized)
        return Indexes(symSpell: symSpell, prefixes: WordPrefixIndex(contents: normalized, locale: language.caseLocale))
    }

    private func makeEmptyIndex() -> SymSpell {
        SymSpell(
            maxDictionaryEditDistance: maxEditDistance,
            prefixLength: prefixLength
        )
    }

    private static func bundledContents(for language: SpellingDictionaryLanguage) -> String? {
        guard let url = resourceURL(for: language) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Xcode may flatten resources or preserve their source folder, so probe both bundle layouts.
    private static func resourceURL(
        for language: SpellingDictionaryLanguage,
        in bundle: Bundle = .main
    ) -> URL? {
        bundle.url(forResource: language.resourceName, withExtension: "txt")
            ?? bundle.url(
                forResource: language.resourceName,
                withExtension: "txt",
                subdirectory: "SpellingDictionaries"
            )
            ?? bundle.url(
                forResource: language.resourceName,
                withExtension: "txt",
                subdirectory: "Resources/SpellingDictionaries"
            )
    }
}
