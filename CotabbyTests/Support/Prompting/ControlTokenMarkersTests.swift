import XCTest
@testable import Cotabby

/// Tests for chat / control-token scaffolding removal. These lock in the three shapes: role-header
/// blocks are removed whole (so the role word cannot leak), opening/role markers are removed in place
/// (adjacent content survives), and stop markers truncate the rest of the completion (a hallucinated
/// new turn must not leak into ghost text).
final class ControlTokenMarkersTests: XCTestCase {
    private func assertSanitized(
        _ cases: [(input: String, expected: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            XCTAssertEqual(
                ControlTokenMarkers.sanitize(testCase.input),
                testCase.expected,
                "input \(testCase.input.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    func test_openingMarkersAreRemovedInPlace() {
        assertSanitized([
            ("a<|im_start|>b", "ab"),
            ("<start_of_turn>hello", "hello"),
            ("<|user|>x<|assistant|>y<|system|>z", "xyz"),
            ("[INST]do it[/INST]the answer", "do itthe answer"),
            // An unpaired Llama-3 header marker falls back to per-marker removal.
            ("text<|end_header_id|> more", "text more")
        ])
    }

    func test_stopMarkersTruncateTheRest() {
        assertSanitized([
            ("good answer<|im_end|>garbage", "good answer"),
            ("keep<|endoftext|>tail", "keep"),
            ("keep<|end|>tail", "keep"),
            ("reply text<end_of_turn>more", "reply text"),
            ("Hello there<|eot_id|>x", "Hello there"),
            // The earliest stop marker wins regardless of list order.
            ("keep<|endoftext|>drop<|im_end|>also drop", "keep")
        ])
    }

    /// Opening markers are stripped before truncation, so only the real answer survives a
    /// hallucinated follow-up turn.
    func test_salvagesPrefixThenDropsHallucinatedTurn() {
        assertSanitized([
            ("Sure thing.<|im_end|><|im_start|>user\nWhat else?", "Sure thing."),
            ("<|im_start|><|im_end|>", "")
        ])
    }

    /// The role word sits between the header markers; stripping the whole block keeps it from
    /// leaking into the ghost text even when no <|eot_id|> precedes the header. The pattern is
    /// non-greedy, so text between two blocks survives.
    func test_llama3HeaderBlockDropsRoleName() {
        assertSanitized([
            ("<|start_header_id|>assistant<|end_header_id|>Hello there", "Hello there"),
            ("<|start_header_id|>user<|end_header_id|>What time is it?", "What time is it?"),
            (
                "<|start_header_id|>assistant<|end_header_id|>Hi <|start_header_id|>user<|end_header_id|>there",
                "Hi there"
            )
        ])
    }

    /// Ordinary text is untouched, including `</s>`, which is deliberately not a stop marker
    /// because it is also the HTML strikethrough close tag.
    func test_leavesOrdinaryTextAndHtmlStrikethroughUnchanged() {
        assertSanitized([
            ("a normal sentence, continuing on", "a normal sentence, continuing on"),
            ("strike <s>this</s> out", "strike <s>this</s> out")
        ])
    }
}
