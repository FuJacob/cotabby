import Foundation
import Logging

/// File overview:
/// Owns Cotabby's language-specific `SymSpell` indexes and exposes synchronous correction lookups
/// for the prediction gate. Index construction is expensive, so dictionaries load on a background
/// queue only when needed. Until a requested language is ready, lookup returns nil and the caller
/// falls back to `NSSpellChecker`.
///
/// `nonisolated` + `@unchecked Sendable` (mirroring `LlamaRuntimeCore`/`FileLogWriter`) because the
/// builds run off the main actor while `bestCorrection` is called from it. The lock protects cache
/// publication, loading state, and LRU metadata. Each `SymSpell` becomes immutable before entering
/// the cache, so readers can safely query a retained instance after releasing the lock.
nonisolated final class SymSpellCorrector: @unchecked Sendable {
    private struct CacheEntry {
        let symSpell: SymSpell
        var lastAccessSequence: UInt64
    }

    typealias ResourceLoader = @Sendable (SpellingDictionaryLanguage) -> String?

    private let lock = NSLock()
    private let maxEditDistance: Int
    private let prefixLength: Int
    private let cacheLimit: Int
    private let resourceLoader: ResourceLoader
    /// All mutable fields below are guarded by `lock`.
    private var cache: [SpellingDictionaryLanguage: CacheEntry] = [:]
    private var loadingLanguages = Set<SpellingDictionaryLanguage>()
    private var accessSequence: UInt64 = 0

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
        self.cacheLimit = max(1, cacheLimit)
        self.resourceLoader = resourceLoader ?? Self.bundledContents(for:)

        if let preloadLanguage {
            requestLoad(for: preloadLanguage)
        }
    }

    /// The best single-word correction for `word`, recased to match it, or nil when the index is not
    /// ready yet, the word is in the dictionary, or nothing is within edit distance. The lookup is
    /// case-insensitive: the dictionary is lowercase, and `TypoCaseTransfer` reapplies the typo's case.
    func bestCorrection(
        for word: String,
        language: SpellingDictionaryLanguage = .english
    ) -> String? {
        guard let symSpell = cachedIndexOrRequestLoad(for: language) else {
            return nil
        }

        let lowered = word.lowercased()
        guard let suggestion = symSpell.bestSuggestion(for: lowered),
              suggestion.distance > 0,
              suggestion.term.lowercased() != lowered else {
            return nil
        }
        return TypoCaseTransfer.applying(caseOf: word, to: suggestion.term)
    }

    /// Test seam: synchronously publishes a small in-memory dictionary without touching the bundle.
    func loadForTesting(
        contents: String,
        language: SpellingDictionaryLanguage = .english
    ) {
        let symSpell = makeEmptyIndex()
        symSpell.loadDictionary(contents: contents)

        lock.lock()
        publish(symSpell, for: language)
        loadingLanguages.remove(language)
        lock.unlock()
    }

    /// Test-only visibility into the bounded cache. The sorted result avoids exposing LRU order.
    var cachedLanguagesForTesting: [SpellingDictionaryLanguage] {
        lock.lock()
        let languages = cache.keys.sorted { $0.rawValue < $1.rawValue }
        lock.unlock()
        return languages
    }

    private func cachedIndexOrRequestLoad(for language: SpellingDictionaryLanguage) -> SymSpell? {
        lock.lock()
        if var entry = cache[language] {
            accessSequence &+= 1
            entry.lastAccessSequence = accessSequence
            cache[language] = entry
            lock.unlock()
            return entry.symSpell
        }
        let shouldLoad = loadingLanguages.insert(language).inserted
        lock.unlock()

        if shouldLoad {
            loadInBackground(language)
        }
        return nil
    }

    private func requestLoad(for language: SpellingDictionaryLanguage) {
        lock.lock()
        let shouldLoad = cache[language] == nil
            && loadingLanguages.insert(language).inserted
        lock.unlock()
        if shouldLoad {
            loadInBackground(language)
        }
    }

    private func loadInBackground(_ language: SpellingDictionaryLanguage) {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let contents = resourceLoader(language) else {
                lock.lock()
                loadingLanguages.remove(language)
                lock.unlock()
                CotabbyLogger.app.error(
                    "SymSpell dictionary resource \(language.resourceName).txt not found in bundle"
                )
                return
            }

            let symSpell = makeEmptyIndex()
            symSpell.loadDictionary(contents: contents)

            lock.lock()
            publish(symSpell, for: language)
            loadingLanguages.remove(language)
            lock.unlock()
            CotabbyLogger.app.info(
                "SymSpell loaded \(symSpell.wordCount) \(language.displayName) words for correction"
            )
        }
    }

    /// Must be called with `lock` held. The newly loaded index is newest, so eviction removes the
    /// least recently used older language and keeps memory bounded even for multilingual users.
    private func publish(_ symSpell: SymSpell, for language: SpellingDictionaryLanguage) {
        accessSequence &+= 1
        cache[language] = CacheEntry(
            symSpell: symSpell,
            lastAccessSequence: accessSequence
        )

        while cache.count > cacheLimit,
              let leastRecentlyUsed = cache.min(by: {
                  $0.value.lastAccessSequence < $1.value.lastAccessSequence
              })?.key {
            cache.removeValue(forKey: leastRecentlyUsed)
        }
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
