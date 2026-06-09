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
}
