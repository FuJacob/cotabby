import XCTest
@testable import Cotabby

/// Tests for the heuristic token-count estimator. It approximates real tokenizers, but the heuristic
/// itself is deterministic (words split on whitespace and punctuation, each word
/// `max(1, round(length / 4))` tokens), and prompt budgeting depends on those exact counts, so the
/// cases pin exact values including the half-way rounding boundary.
final class TokenCountEstimatorTests: XCTestCase {
    func test_estimate_matchesWordAwareHeuristic() {
        let cases: [(text: String, expected: Int)] = [
            ("", 0),
            ("   \n\t ", 0),
            ("...", 0),                      // punctuation alone is not a word
            ("a", 1),                        // every word is at least one token
            ("hi there", 2),
            ("abcde", 1),                    // 1.25 rounds down
            ("abcdef", 2),                   // 1.5 rounds away from zero
            ("abcdefghij", 3),               // 2.5 rounds away from zero
            ("internationalization", 5),
            ("word word word word word", 5), // scales linearly with word count
            ("cant", 1),
            ("can't", 2),                    // punctuation splits a contraction
            ("foobarbaz", 2),
            ("foo.bar.baz", 3),              // and a dotted identifier
            ("func(x)", 2)
        ]
        for testCase in cases {
            XCTAssertEqual(
                TokenCountEstimator.estimate(testCase.text),
                testCase.expected,
                "text \(testCase.text.debugDescription)"
            )
        }
    }
}
