import XCTest
@testable import Cotabby

/// Tests for chat / control-token scaffolding removal. These lock in the two shapes: opening/role
/// markers are removed in place (adjacent content survives), while stop markers truncate the rest of
/// the completion (a hallucinated new turn must not leak into ghost text).
final class ControlTokenMarkersTests: XCTestCase {
    func testRemovesOpeningMarkerKeepingSurroundingText() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("a<|im_start|>b"), "ab")
    }

    func testTruncatesAtStopMarker() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("good answer<|im_end|>garbage"), "good answer")
    }

    func testSalvagesPrefixThenDropsHallucinatedTurn() {
        // Remove the opening marker, then truncate at the stop marker; only the real answer survives.
        let cleaned = ControlTokenMarkers.sanitize("Sure thing.<|im_end|><|im_start|>user\nWhat else?")
        XCTAssertEqual(cleaned, "Sure thing.")
    }

    func testEarliestStopMarkerWins() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("keep<|endoftext|>drop<|im_end|>also drop"), "keep")
    }

    func testOnlyMarkersBecomesEmpty() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("<|im_start|><|im_end|>"), "")
    }

    func testNoMarkersIsUnchanged() {
        XCTAssertEqual(
            ControlTokenMarkers.sanitize("a normal sentence, continuing on"),
            "a normal sentence, continuing on"
        )
    }

    func testGemmaEndOfTurnTruncates() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("reply text<end_of_turn>more"), "reply text")
    }

    func testInstMarkersAreRemoved() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("[INST]do it[/INST]the answer"), "do itthe answer")
    }

    func testLlama3EotTruncates() {
        XCTAssertEqual(ControlTokenMarkers.sanitize("Hello there<|eot_id|>x"), "Hello there")
    }

    func testLlama3HeaderBlockDropsRoleNameWithoutStopToken() {
        // The role word sits between the header markers; stripping the whole block keeps it from
        // leaking into the ghost text even when no <|eot_id|> precedes the header.
        XCTAssertEqual(
            ControlTokenMarkers.sanitize("<|start_header_id|>assistant<|end_header_id|>Hello there"),
            "Hello there"
        )
        XCTAssertEqual(
            ControlTokenMarkers.sanitize("<|start_header_id|>user<|end_header_id|>What time is it?"),
            "What time is it?"
        )
    }

    func testPreservesHtmlStrikethroughCloseTag() {
        // `</s>` is intentionally not a stop marker (it is also the HTML strikethrough close tag),
        // so HTML-flavored completions are not truncated on it.
        XCTAssertEqual(
            ControlTokenMarkers.sanitize("strike <s>this</s> out"),
            "strike <s>this</s> out"
        )
    }

    /// A pasted ChatML transcript (2026-09-11): the model continued the note, then opened the next
    /// turn on its own line.
    func testATurnOpeningOnItsOwnLineEndsTheContinuation() {
        XCTAssertEqual(
            ControlTokenMarkers.sanitize(" to unplug the router for 10 seconds.\n<|im_start|>user\nHow do I reset my router?<|im_end|>"),
            " to unplug the router for 10 seconds.\n"
        )
        XCTAssertEqual(
            ControlTokenMarkers.sanitize(" challenging hike with stunning views.\n  <|user|>\nWhat else?"),
            " challenging hike with stunning views.\n  "
        )
        XCTAssertEqual(ControlTokenMarkers.sanitize("<|im_start|>assistant\nHello"), "assistant\nHello", "a leading marker is removed in place")
        XCTAssertEqual(ControlTokenMarkers.sanitize("\n<|im_start|>Hello"), "\nHello", "no text before the line: nothing ended")
    }
}
