import XCTest
@testable import Cotabby

final class SymSpellCorrectorTests: XCTestCase {
    private func makeLoadedCorrector() -> SymSpellCorrector {
        let corrector = SymSpellCorrector(autoload: false)
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
        let corrector = SymSpellCorrector(autoload: false)
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
}
