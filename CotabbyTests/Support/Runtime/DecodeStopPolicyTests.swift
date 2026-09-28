import XCTest
@testable import Cotabby

/// Tests for the decode-time early-stop decision. These lock in that generation stops at a genuine
/// sentence boundary, stays running through abbreviations / decimals / initialisms, respects the
/// minimum-token guard that prevents degenerate instant stops, and stops immediately on template
/// scaffolding markers.
final class DecodeStopPolicyTests: XCTestCase {
    private typealias Reason = DecodeStopPolicy.StopReason

    func test_verdict_sentenceBoundaryDecisions() {
        // `minimumTokens` defaults to 2 unless a row overrides it.
        let cases: [(text: String, tokens: Int, minimum: Int?, expected: Reason?)] = [
            ("Hello there.", 3, nil, .sentenceBoundary),
            ("Are you sure?", 3, nil, .sentenceBoundary),
            ("That works!", 2, nil, .sentenceBoundary),
            ("All done. ", 3, nil, .sentenceBoundary),
            // Even a complete sentence should not stop before the minimum token count.
            ("Hello there.", 1, nil, nil),
            ("Hi.", 2, 3, nil),
            ("Hi.", 3, 3, .sentenceBoundary),
            // SentenceBoundaryClassifier keeps these mid-thought.
            ("Please meet Dr.", 3, nil, nil),
            ("Made in the U.S.", 4, nil, nil),
            ("Pi is about 3.14", 4, nil, nil),
            ("still going strong", 5, nil, nil)
        ]
        for testCase in cases {
            let verdict: Reason?
            if let minimum = testCase.minimum {
                verdict = DecodeStopPolicy.verdict(
                    accumulated: testCase.text,
                    tokensGenerated: testCase.tokens,
                    minimumTokens: minimum
                )
            } else {
                verdict = DecodeStopPolicy.verdict(accumulated: testCase.text, tokensGenerated: testCase.tokens)
            }
            XCTAssertEqual(
                verdict,
                testCase.expected,
                "\"\(testCase.text)\" tokens=\(testCase.tokens) minimum=\(testCase.minimum ?? 2)"
            )
        }
    }

    func test_verdict_everyStopMarkerStopsEvenBelowTheMinimum() {
        // A stop marker means the model believes the turn is over; the minimum-token guard only
        // protects the sentence-boundary heuristic, never delays a marker stop.
        for marker in ["<|im_end|>", "<|endoftext|>", "<|end|>", "<end_of_turn>", "<|eot_id|>"] {
            XCTAssertEqual(
                DecodeStopPolicy.verdict(accumulated: "Sounds good\(marker)", tokensGenerated: 0, minimumTokens: 3),
                .scaffoldingMarker,
                marker
            )
        }
    }

    func test_verdict_markerTakesPrecedenceOverASentenceBoundary() {
        XCTAssertEqual(
            DecodeStopPolicy.verdict(accumulated: "Done.<|im_end|>", tokensGenerated: 5),
            .scaffoldingMarker
        )
    }

    func test_verdict_markerMustBeCompleteInTheAccumulatedText() {
        // The marker can arrive split across token pieces; only the accumulated text matters.
        XCTAssertNil(DecodeStopPolicy.verdict(accumulated: "Done<|im_", tokensGenerated: 3))
        XCTAssertEqual(
            DecodeStopPolicy.verdict(accumulated: "Done<|im_end|>", tokensGenerated: 4),
            .scaffoldingMarker
        )
    }

    func test_verdict_angleBracketTextThatIsNotAMarkerDoesNotStop() {
        // `</s>` is deliberately not a stop marker (it is the closing HTML strikethrough tag).
        XCTAssertNil(DecodeStopPolicy.verdict(accumulated: "<s>old</s> new", tokensGenerated: 5))
        XCTAssertNil(DecodeStopPolicy.verdict(accumulated: "if a <b", tokensGenerated: 1))
    }

    func test_stopReason_rawValuesMatchTheDecodeLogContract() {
        // These strings land in the decode log's `stop_reason` field that jq recipes filter on.
        XCTAssertEqual(Reason.sentenceBoundary.rawValue, "sentence_boundary")
        XCTAssertEqual(Reason.scaffoldingMarker.rawValue, "scaffolding_marker")
    }

    func testSentenceStopWaitsForTheMinimumWordCount() {
        // "report." is a sentence end after one word; with a four-word minimum decoding continues.
        XCTAssertNil(DecodeStopPolicy.verdict(accumulated: " report.", tokensGenerated: 3, minimumWords: 4))
        XCTAssertEqual(
            DecodeStopPolicy.verdict(accumulated: " the report by Friday.", tokensGenerated: 6, minimumWords: 4),
            .sentenceBoundary
        )
    }
}
