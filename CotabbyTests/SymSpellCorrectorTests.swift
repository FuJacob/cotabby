import AppKit
import XCTest
@testable import Cotabby

final class SymSpellCorrectorTests: XCTestCase {
    private func makeLoadedCorrector() -> SymSpellCorrector {
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(contents: """
        the 1000000
        name 50000
        receive 8000
        separate 4000
        """)
        return corrector
    }

    func test_returnsNilBeforeIndexIsReady() {
        // autoload off and never loaded: callers must fall back gracefully.
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        XCTAssertNil(corrector.bestCorrection(for: "teh"))
    }

    func test_correctsMisspelledWord() {
        XCTAssertEqual(makeLoadedCorrector().bestCorrection(for: "recieve"), "receive")
        XCTAssertEqual(makeLoadedCorrector().bestCorrection(for: "seperate"), "separate")
    }

    func test_transfersCapitalization() {
        XCTAssertEqual(makeLoadedCorrector().bestCorrection(for: "Teh"), "The")
    }

    func test_returnsNilForCorrectWord() {
        // A word already in the dictionary is not a typo, so there is no correction to offer.
        XCTAssertNil(makeLoadedCorrector().bestCorrection(for: "name"))
    }

    func test_returnsNilForGibberish() {
        XCTAssertNil(makeLoadedCorrector().bestCorrection(for: "qwxzy"))
    }

    func test_keepsLanguageIndexesSeparate() {
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(
            contents: """
            gift 1000
            give 500
            """,
            language: .english
        )
        corrector.loadForTesting(
            contents: """
            gibt 1000
            gift 10
            """,
            language: .german
        )

        XCTAssertEqual(
            corrector.bestCorrection(for: "gibt", language: .english),
            "gift"
        )
        XCTAssertNil(corrector.bestCorrection(for: "gibt", language: .german))
    }

    func test_evictsLeastRecentlyUsedLanguageAtCacheLimit() {
        let corrector = SymSpellCorrector(cacheLimit: 2, preloadLanguage: nil)
        corrector.loadForTesting(contents: "the 1000", language: .english)
        corrector.loadForTesting(contents: "das 1000", language: .german)

        // Touch English after German so German becomes the least-recently-used entry.
        XCTAssertNil(corrector.bestCorrection(for: "the", language: .english))
        corrector.loadForTesting(contents: "hola 1000", language: .spanish)

        XCTAssertEqual(corrector.cachedLanguagesForTesting, [.english, .spanish])
    }

    func test_missingDictionaryResourceFailsOpenAndCachesNothing() {
        let loaderConsulted = expectation(description: "resource loader consulted for the missing language")
        // The retry below may legitimately schedule a second load once the failed one has been
        // forgotten; over-fulfillment is therefore expected behavior, not a test error.
        loaderConsulted.assertForOverFulfill = false
        let corrector = SymSpellCorrector(
            preloadLanguage: nil,
            resourceLoader: { language in
                XCTAssertEqual(language, .italian)
                loaderConsulted.fulfill()
                return nil
            }
        )

        // The first lookup schedules the background load; no index is ready yet.
        XCTAssertNil(corrector.bestCorrection(for: "ciaoo", language: .italian))

        wait(for: [loaderConsulted], timeout: 5.0)

        // A failed load publishes nothing: lookups keep failing open and the cache stays empty,
        // so callers fall back to NSSpellChecker instead of crashing or blocking.
        XCTAssertNil(corrector.bestCorrection(for: "ciaoo", language: .italian))
        XCTAssertEqual(corrector.cachedLanguagesForTesting, [])
    }
}

/// Behavioral contract tests for the `NSSpellChecker` wrapper used by the typo gate.
///
/// `NSSpellChecker` verdicts depend on the machine's spelling configuration, enabled languages, and
/// learned words, so these tests deliberately avoid pinning concrete dictionary verdicts. They
/// instead assert the wrapper's documented contracts relative to the live spell server: whole-word
/// range interpretation for `isTypo`, faithful pass-through of ranked guesses for
/// `nativeCorrections`, and the single-word, case-transferred shape of `bestCorrection`. Those
/// relations hold on any machine because both sides of each assertion query the same engine.
@MainActor
final class CurrentWordSpellCheckerTests: XCTestCase {
    /// Mix of well-formed words, misspellings, partially-flagged tokens, trailing punctuation, and
    /// gibberish, so every range-interpretation branch is exercised on a typical machine while the
    /// relative assertions stay true on any machine.
    private let probeWords = ["hello", "helo", "nmae,", "ok nmae", "I'm", "Teh", "qqqqzzzzqq"]

    /// App-hosted tests have crashed deallocating short-lived `@MainActor` objects, so checkers are
    /// retained for the process lifetime (mirrors `SuggestionStateHelperTests`).
    private static var retainedCheckers: [CurrentWordSpellChecker] = []

    private func makeChecker() -> CurrentWordSpellChecker {
        let checker = CurrentWordSpellChecker()
        Self.retainedCheckers.append(checker)
        return checker
    }

    func test_isTypo_emptyWordIsNeverATypo() async {
        XCTAssertFalse(makeChecker().isTypo(""))
    }

    func test_isTypo_mirrorsSpellServerWholeWordRange() async {
        let checker = makeChecker()
        let probeTag = NSSpellChecker.uniqueSpellDocumentTag()
        for word in probeWords {
            let flagged = NSSpellChecker.shared.checkSpelling(
                of: word,
                startingAt: 0,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: probeTag,
                wordCount: nil
            )
            // The wrapper's whole job is range interpretation: a typo only when the flagged range
            // starts at 0 and spans the entire token (so "I'm" and "nmae," do not misfire).
            let expected = flagged.location == 0 && flagged.length == (word as NSString).length
            XCTAssertEqual(
                checker.isTypo(word),
                expected,
                "isTypo(\"\(word)\") must mirror the spell server range \(flagged)"
            )
        }
    }

    func test_nativeCorrections_passesRankedGuessesThroughNeverNil() async {
        let checker = makeChecker()
        let probeTag = NSSpellChecker.uniqueSpellDocumentTag()
        for word in ["helo", "qqqqzzzzqq"] {
            let fullRange = NSRange(location: 0, length: (word as NSString).length)
            let rawGuesses = NSSpellChecker.shared.guesses(
                forWordRange: fullRange,
                in: word,
                language: nil,
                inSpellDocumentWithTag: probeTag
            ) ?? []
            XCTAssertEqual(checker.nativeCorrections(for: word), rawGuesses)
        }
    }

    func test_bestCorrection_returnsNilOrADifferentSingleWord() async {
        let checker = makeChecker()
        for word in probeWords {
            guard let correction = checker.bestCorrection(for: word) else { continue }
            XCTAssertFalse(correction.isEmpty, "\"\(word)\" produced an empty correction")
            // Single-word fixes only: a space would break the one-word-replace delete math.
            XCTAssertFalse(correction.contains(" "), "\"\(word)\" produced a multi-word correction")
            XCTAssertNotEqual(correction.lowercased(), word.lowercased())
        }
    }

    func test_bestCorrection_transfersLeadingCapitalFromTypo() async {
        guard let correction = makeChecker().bestCorrection(for: "Teh") else {
            // This machine's dictionaries offered no usable guess; the case-transfer contract is
            // vacuous here rather than failed.
            return
        }
        XCTAssertEqual(
            correction.first?.isUppercase,
            true,
            "a capitalized typo must yield a capitalized correction, got \(correction)"
        )
    }
}
