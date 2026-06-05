import Foundation
import Logging

/// File overview:
/// Owns the app's single `SymSpell` instance and exposes a synchronous `bestCorrection(for:)` that
/// the prediction gate can call inline. The frequency dictionary is large, so the index is built
/// once on a background queue at startup; until that finishes, `bestCorrection` returns nil and the
/// caller falls back to `NSSpellChecker`. After the build the index is read-only, so a single lock
/// that publishes the "ready" flag is enough to share it safely with main-actor readers.
///
/// `nonisolated` + `@unchecked Sendable` (mirroring `LlamaRuntimeCore`/`FileLogWriter`) because the
/// build runs off the main actor while `bestCorrection` is called from it; the lock is the sole
/// synchronization and the `SymSpell` instance is never mutated after the build completes.
nonisolated final class SymSpellCorrector: @unchecked Sendable {
    private let symSpell: SymSpell
    private let lock = NSLock()
    /// Guarded by `lock`. Set true only after `loadDictionary` returns, which (via the lock's
    /// release/acquire barrier) publishes the fully-built index to readers.
    private var isReady = false

    private static let resourceName = "frequency_dictionary_en_82_765"

    init(maxEditDistance: Int = 2, prefixLength: Int = 7, autoload: Bool = true) {
        symSpell = SymSpell(maxDictionaryEditDistance: maxEditDistance, prefixLength: prefixLength)
        guard autoload else { return }
        // Build off the main thread: parsing 82k words and precomputing the delete index is on the
        // order of a second, which must never block app launch or the typing hot path.
        DispatchQueue.global(qos: .utility).async { [self] in
            loadFromBundle()
        }
    }

    /// The best single-word correction for `word`, recased to match it, or nil when the index is not
    /// ready yet, the word is in the dictionary, or nothing is within edit distance. The lookup is
    /// case-insensitive: the dictionary is lowercase, and `TypoCaseTransfer` reapplies the typo's case.
    func bestCorrection(for word: String) -> String? {
        lock.lock()
        let ready = isReady
        lock.unlock()
        guard ready else { return nil }

        let lowered = word.lowercased()
        guard let suggestion = symSpell.bestSuggestion(for: lowered),
              suggestion.distance > 0,
              suggestion.term.lowercased() != lowered else {
            return nil
        }
        return TypoCaseTransfer.applying(caseOf: word, to: suggestion.term)
    }

    /// Test seam: load a dictionary synchronously instead of from the bundle.
    func loadForTesting(contents: String) {
        symSpell.loadDictionary(contents: contents)
        lock.lock()
        isReady = true
        lock.unlock()
    }

    private func loadFromBundle() {
        guard let url = Self.resourceURL(),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            CotabbyLogger.app.error("SymSpell dictionary resource \(Self.resourceName).txt not found in bundle")
            return
        }
        symSpell.loadDictionary(contents: contents)
        lock.lock()
        isReady = true
        lock.unlock()
        CotabbyLogger.app.info("SymSpell loaded \(symSpell.wordCount) words for correction")
    }

    /// Xcode may flatten the resource into `Resources/` or preserve the folder, so probe both.
    private static func resourceURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "txt")
            ?? bundle.url(forResource: resourceName, withExtension: "txt", subdirectory: "Resources")
    }
}
