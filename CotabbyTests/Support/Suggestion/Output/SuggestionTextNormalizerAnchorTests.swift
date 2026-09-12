import XCTest
@testable import Cotabby

final class SuggestionTextNormalizerAnchorTests: XCTestCase {
    private func request(preceding: String, anchor: String?, trailing: String = "") -> SuggestionRequest {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: preceding, trailingText: trailing)
        return SuggestionRequest(
            context: context,
            prefixText: anchor.map { WordBoundaryAnchorPolicy.promptPrefix(preceding, removing: $0) } ?? preceding,
            prompt: "PROMPT",
            generation: 1,
            maxPredictionTokens: 8,
            temperature: 0.2,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repetitionPenalty: 1.1,
            randomSeed: nil,
            maxSuffixCharacters: 40,
            completionLengthInstruction: "",
            userName: nil,
            customRules: [],
            languageInstruction: nil,
            clipboardContext: nil,
            visualContextSummary: nil,
            isMultiLineEnabled: false,
            wordBoundaryAnchor: anchor
        )
    }

    func testAnchoredCompletionShowsOnlyTheUntypedRemainder() {
        let result = SuggestionTextNormalizer.normalizeDetailed(" appreciate it!", for: request(preceding: "I really apprec", anchor: "apprec"))
        XCTAssertEqual(result.text, "iate it!")
        XCTAssertNil(result.suppression)
    }

    func testAnchoredCompletionOfADifferentWordIsSuppressed() {
        let result = SuggestionTextNormalizer.normalizeDetailed(" approve it", for: request(preceding: "I really apprec", anchor: "apprec"))
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppression, .wordBoundaryMismatch)
    }

    func testPunctuationOnlyAndScaffoldingAreSuppressedWithReasons() {
        XCTAssertEqual(SuggestionTextNormalizer.normalizeDetailed(",\n\n-John", for: request(preceding: "Best ", anchor: nil)).suppression, .noWordContent)
        XCTAssertEqual(
            SuggestionTextNormalizer.normalizeDetailed("! the view was beautiful", for: request(preceding: "do it again ", anchor: nil)).suppression,
            .punctuationAfterSpace
        )
        XCTAssertEqual(
            SuggestionTextNormalizer.normalizeDetailed("\n\n[User 0001]\n\n<blockquote>", for: request(preceding: "asdkfj ", anchor: nil)).suppression,
            .scaffolding
        )
    }

    func testOrdinaryContinuationsStillPass() {
        let result = SuggestionTextNormalizer.normalizeDetailed(" soon, maybe next weekend", for: request(preceding: "do it again", anchor: nil))
        XCTAssertEqual(result.text, " soon, maybe next weekend")
    }
}
