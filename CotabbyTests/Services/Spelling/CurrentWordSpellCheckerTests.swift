import XCTest
@testable import Cotabby

/// Behavioral contract tests for the `NSSpellChecker` wrapper used by the typo gate.
///
/// `NSSpellChecker` verdicts depend on the machine's spelling configuration, enabled languages, and
/// learned words, so these tests deliberately avoid pinning concrete dictionary verdicts. They
/// instead assert the wrapper's documented contracts that hold on any machine: an empty word is
/// never a typo, and `bestCorrection` is nil or a different, single, case-transferred word.
@MainActor
final class CurrentWordSpellCheckerTests: XCTestCase {
    /// Mix of well-formed words, misspellings, partially-flagged tokens, trailing punctuation, and
    /// gibberish, so every range-interpretation branch is exercised on a typical machine while the
    /// relative assertions stay true on any machine.
    private let probeWords = ["hello", "helo", "nmae,", "ok nmae", "I'm", "Teh", "qqqqzzzzqq"]

    private func makeChecker() -> CurrentWordSpellChecker {
        TestLifetime.retain(CurrentWordSpellChecker())
    }

    func test_isTypo_emptyWordIsNeverATypo() {
        XCTAssertFalse(makeChecker().isTypo(""))
    }

    func test_bestCorrection_returnsNilOrADifferentSingleWord() {
        let checker = makeChecker()
        for word in probeWords {
            guard let correction = checker.bestCorrection(for: word) else { continue }
            XCTAssertFalse(correction.isEmpty, "\"\(word)\" produced an empty correction")
            // Single-word fixes only: a space would break the one-word-replace delete math.
            XCTAssertFalse(correction.contains(" "), "\"\(word)\" produced a multi-word correction")
            XCTAssertNotEqual(correction.lowercased(), word.lowercased())
        }
    }

    func test_bestCorrection_transfersLeadingCapitalFromTypo() {
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
