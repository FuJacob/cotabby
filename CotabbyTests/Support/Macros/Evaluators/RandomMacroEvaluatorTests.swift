import XCTest
@testable import Cotabby

/// Tests for the random and generator macro family (`/random`, `/dice`, `/dN`, `/coin`, `/uuid`).
///
/// The injected RNG is a recorder: it returns a configurable value and remembers the range the
/// evaluator asked for. Pinning the requested range is what actually proves `/d20` rolls 1...20 or
/// `/random(2,1)` normalizes its bounds; a lower-bound-only stub would pass for many wrong ranges.
final class RandomMacroEvaluatorTests: XCTestCase {
    /// Shared mutable state between the escaping RNG closure and the test body. A class so both see
    /// the same instance; XCTest builds a fresh test-case object (and so a fresh recorder) per test.
    private final class RandomSourceRecorder {
        var requestedRanges: [ClosedRange<Int>] = []
        var pick: (ClosedRange<Int>) -> Int = { $0.lowerBound }
    }

    private let recorder = RandomSourceRecorder()

    private func makeSUT() -> RandomMacroEvaluator {
        let recorder = recorder
        return RandomMacroEvaluator(
            randomSource: { range in
                recorder.requestedRanges.append(range)
                return recorder.pick(range)
            },
            uuidSource: { "FIXED-UUID" }
        )
    }

    // MARK: - Keyword macros and their aliases

    func test_keywordMacros_requestTheirDocumentedRanges() {
        let cases: [(query: String, range: ClosedRange<Int>)] = [
            ("random", 0...100), ("rand", 0...100), ("rnd", 0...100),
            ("dice", 1...6), ("die", 1...6), ("roll", 1...6),
            ("coin", 0...1), ("flip", 0...1), ("coinflip", 0...1), ("coin-flip", 0...1)
        ]
        for (query, range) in cases {
            recorder.requestedRanges.removeAll()
            XCTAssertNotNil(makeSUT().evaluate(query), query)
            XCTAssertEqual(recorder.requestedRanges, [range], query)
        }
    }

    func test_numericResults_insertTheRolledValue() {
        recorder.pick = { $0.upperBound }
        let sut = makeSUT()
        XCTAssertEqual(sut.evaluate("random")?.insertionText, "100")
        XCTAssertEqual(sut.evaluate("dice")?.insertionText, "6")
    }

    func test_previewAndInsertionAreIdentical() {
        let result = makeSUT().evaluate("dice")
        XCTAssertEqual(result, MacroResult(previewText: "1", insertionText: "1"))
    }

    func test_coin_mapsZeroToHeadsAndOneToTails() {
        XCTAssertEqual(makeSUT().evaluate("coin")?.insertionText, "Heads")
        recorder.pick = { $0.upperBound }
        XCTAssertEqual(makeSUT().evaluate("flip")?.insertionText, "Tails")
    }

    func test_uuidAndGuid_useTheInjectedSourceWithoutTouchingTheRNG() {
        let sut = makeSUT()
        XCTAssertEqual(sut.evaluate("uuid")?.insertionText, "FIXED-UUID")
        XCTAssertEqual(sut.evaluate("guid")?.insertionText, "FIXED-UUID")
        XCTAssertTrue(recorder.requestedRanges.isEmpty)
    }

    func test_keywordsAreCaseInsensitive() {
        let sut = makeSUT()
        XCTAssertEqual(sut.evaluate("UUID")?.insertionText, "FIXED-UUID")
        XCTAssertEqual(sut.evaluate("Coin")?.insertionText, "Heads")
    }

    // MARK: - dN dice notation

    func test_diceNotation_rollsOneThroughSides() {
        XCTAssertEqual(makeSUT().evaluate("d20")?.insertionText, "1")
        XCTAssertEqual(recorder.requestedRanges, [1...20])
    }

    func test_diceNotation_rejectsZeroSidesAndBareD() {
        // `d0` and `d` are not dice, and must fall through (returning nil) so other families can try.
        let sut = makeSUT()
        XCTAssertNil(sut.evaluate("d0"))
        XCTAssertNil(sut.evaluate("d"))
        XCTAssertNil(sut.evaluate("dollar"))
        XCTAssertTrue(recorder.requestedRanges.isEmpty)
    }

    // MARK: - Parameterized random(...)

    func test_singleArgument_rollsOneThroughN() {
        XCTAssertEqual(makeSUT().evaluate("random(5)")?.insertionText, "1")
        XCTAssertEqual(recorder.requestedRanges, [1...5])
    }

    func test_twoArguments_normalizeReversedBounds() {
        XCTAssertEqual(makeSUT().evaluate("random(9, 3)")?.insertionText, "3")
        XCTAssertEqual(recorder.requestedRanges, [3...9])
    }

    func test_twoArguments_acceptNegativeBounds() {
        XCTAssertEqual(makeSUT().evaluate("random(-3,-1)")?.insertionText, "-3")
        XCTAssertEqual(recorder.requestedRanges, [-3 ... -1])
    }

    func test_shortFormPrefixes_acceptArguments() {
        let sut = makeSUT()
        XCTAssertEqual(sut.evaluate("rand(4)")?.insertionText, "1")
        XCTAssertEqual(sut.evaluate("rnd(7,7)")?.insertionText, "7")
        XCTAssertEqual(recorder.requestedRanges, [1...4, 7...7])
    }

    func test_invalidArguments_returnNilWithoutRolling() {
        let sut = makeSUT()
        for query in ["random(abc)", "random(0)", "random(-2)", "random()", "random(1,2,3)", "random(1,x)", "random(5"] {
            XCTAssertNil(sut.evaluate(query), query)
        }
        XCTAssertTrue(recorder.requestedRanges.isEmpty)
    }

    func test_unrelatedQuery_returnsNil() {
        XCTAssertNil(makeSUT().evaluate("today"))
    }
}
