import XCTest
@testable import Cotabby

/// Pure tests for FIM marker detection and prompt assembly. No runtime is involved: the vocabulary is
/// supplied as a stub, so detection and the prefix-suffix-middle ordering and trimming are deterministic.
final class FillInMiddlePolicyTests: XCTestCase {
    private func vocab(_ strings: [String]) -> (Int, (Int) -> [UInt8]) {
        let bytes = strings.map { Array($0.utf8) }
        return (bytes.count, { bytes[$0] })
    }

    func test_detectMarkers_findsAllThree() {
        let (size, bytesFor) = vocab([
            "hello",
            FillInMiddlePolicy.prefixMarker,
            "x",
            FillInMiddlePolicy.middleMarker,
            FillInMiddlePolicy.suffixMarker
        ])
        XCTAssertEqual(
            FillInMiddlePolicy.detectMarkers(vocabSize: size, bytesFor: bytesFor),
            FIMMarkers(prefix: 1, suffix: 4, middle: 3))
    }

    func test_detectMarkers_nilWhenAnyMarkerMissing() {
        // No middle marker -> not FIM-capable.
        let (size, bytesFor) = vocab(["hi", FillInMiddlePolicy.prefixMarker, FillInMiddlePolicy.suffixMarker])
        XCTAssertNil(FillInMiddlePolicy.detectMarkers(vocabSize: size, bytesFor: bytesFor))
    }

    func test_assemble_ordersPrefixSuffixMiddle() {
        let markers = FIMMarkers(prefix: 100, suffix: 101, middle: 102)
        let tokens = FillInMiddlePolicy.assemblePromptTokens(
            prefixTokens: [1, 2, 3], suffixTokens: [7, 8], markers: markers, maxTokens: 50)
        XCTAssertEqual(tokens, [100, 1, 2, 3, 101, 7, 8, 102])
    }

    func test_assemble_trimsTowardCaretWhenOverBudget() {
        let markers = FIMMarkers(prefix: 100, suffix: 101, middle: 102)
        // budget = 8 - 3 = 5; suffix keeps its head (up to 2), prefix keeps its tail (the rest).
        let tokens = FillInMiddlePolicy.assemblePromptTokens(
            prefixTokens: [1, 2, 3, 4, 5, 6], suffixTokens: [7, 8, 9, 10], markers: markers, maxTokens: 8)
        XCTAssertEqual(tokens, [100, 4, 5, 6, 101, 7, 8, 102])
        XCTAssertLessThanOrEqual(tokens.count, 8)
    }

    func test_assemble_keepsMarkersEvenWithTinyBudget() {
        let markers = FIMMarkers(prefix: 1, suffix: 2, middle: 3)
        let tokens = FillInMiddlePolicy.assemblePromptTokens(
            prefixTokens: [9], suffixTokens: [9], markers: markers, maxTokens: 2)
        XCTAssertEqual(tokens, [1, 2, 3], "the three markers are mandatory even when the budget is exhausted")
    }
}
