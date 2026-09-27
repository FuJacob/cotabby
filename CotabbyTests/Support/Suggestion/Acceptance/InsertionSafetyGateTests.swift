import XCTest
@testable import Cotabby

/// Pure-function tests for the last-mile insertion safety gate: unambiguous junk (empty,
/// whitespace-only, lossy-decode glyphs, control characters) is refused, while real content,
/// including lone structural punctuation and multi-line text, passes.
final class InsertionSafetyGateTests: XCTestCase {
    func test_legitimateCompletionsAreSafe() {
        let cases: [(String, String)] = [
            ("hello there", "plain prose"),
            (")", "closing a bracket is a legitimate inline completion"),
            (".", "ending a sentence is a legitimate inline completion"),
            ("first line\nsecond line", "a line feed is content in multi-line mode"),
            ("  indented", "leading whitespace is fine when real text follows"),
            ("🎉 café", "non-ASCII scalars are not control characters")
        ]
        for (completion, reason) in cases {
            XCTAssertTrue(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    func test_junkCompletionsAreUnsafe() {
        let cases: [(String, String)] = [
            ("", "empty"),
            ("   ", "whitespace-only"),
            ("\n\n", "newline-only is still whitespace-only"),
            ("\u{00A0}", "a non-breaking space is whitespace"),
            ("ab\u{FFFD}cd", "replacement glyph from lossy detokenization"),
            ("a\tb", "interior tab"),
            ("a\u{1B}b", "stray escape"),
            ("a\u{7F}b", "DEL sits outside the C0 range but is still a control character"),
            ("a\rb", "only the line feed is exempt, so a carriage return is refused")
        ]
        for (completion, reason) in cases {
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }
}
