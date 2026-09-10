import XCTest
@testable import Cotabby

/// The sampler turns the caret's own movement into a width sample of the host's real glyphs; these
/// cases are the ways a focus poll can lie about typing, each measured in a Chromium host.
final class CaretAdvanceSamplerTests: XCTestCase {
    private func observation(
        _ text: String,
        x: CGFloat,
        y: CGFloat = 100,
        caret: Int? = nil,
        positioned: Bool = true
    ) -> CaretAdvanceSampler.Observation {
        CaretAdvanceSampler.Observation(
            caretX: x,
            lineY: y,
            documentCaret: caret ?? text.count,
            precedingText: text,
            isPositioned: positioned
        )
    }

    /// Types `text` one character per poll at `advance` points each, starting after `prefix`.
    private func typed(_ text: String, after prefix: String, from x: CGFloat, advance: CGFloat, into sampler: inout CaretAdvanceSampler) -> CGFloat {
        var current = prefix
        var caretX = x
        sampler.observe(observation(current, x: caretX))
        for character in text {
            current.append(character)
            caretX += advance
            sampler.observe(observation(current, x: caretX))
        }
        return caretX
    }

    func testSameLineTypingAccumulatesIntoOneSample() {
        var sampler = CaretAdvanceSampler()
        _ = typed("the user writes", after: "make it pill, as", from: 500, advance: 7.5, into: &sampler)
        let sample = sampler.sample
        XCTAssertEqual(sample?.text, "the user writes")
        XCTAssertEqual(sample?.width ?? 0, 7.5 * 15, accuracy: 0.001)
    }

    func testNothingIsOfferedBeforeTheMinimumLength() {
        var sampler = CaretAdvanceSampler()
        _ = typed("the user wr", after: "as", from: 500, advance: 7.5, into: &sampler)
        XCTAssertNil(sampler.sample, "11 characters carry too much rounding to scale a face")
        _ = typed("i", after: "asthe user wr", from: 500 + 7.5 * 11, advance: 7.5, into: &sampler)
        XCTAssertEqual(sampler.sample?.text, "the user wri")
    }

    func testASampleNeverEndsOnASpaceBecauseALineEndSpaceMayHang() {
        var sampler = CaretAdvanceSampler()
        let x = typed("the user writes", after: "as", from: 500, advance: 7.5, into: &sampler)
        // The space at the end of the line advances nothing until the next letter arrives.
        sampler.observe(observation("asthe user writes ", x: x))
        XCTAssertEqual(sampler.sample?.text, "the user writes", "the running sample stays at the last letter")
        // The next letter carries the deferred space with it: the total is still right.
        sampler.observe(observation("asthe user writes a", x: x + 3.8 + 7.5))
        XCTAssertEqual(sampler.sample?.text, "the user writes a")
        XCTAssertEqual(sampler.sample?.width ?? 0, 7.5 * 16 + 3.8, accuracy: 0.001)
    }

    func testAnIdlePollChangesNothing() {
        // Focus polls run every 80ms whether or not a key was pressed; a poll that saw no change
        // must not reset the evidence gathered so far.
        var sampler = CaretAdvanceSampler()
        let x = typed("the user writes", after: "as", from: 500, advance: 7.5, into: &sampler)
        for _ in 0..<5 {
            sampler.observe(observation("asthe user writes", x: x))
        }
        XCTAssertEqual(sampler.sample?.text, "the user writes")
        _ = typed(" more", after: "asthe user writes", from: x, advance: 7.5, into: &sampler)
        XCTAssertEqual(sampler.sample?.text, "the user writes more")
    }

    func testAnEstimatedCaretContributesNothing() {
        var sampler = CaretAdvanceSampler()
        sampler.observe(observation("as", x: 500, positioned: false))
        sampler.observe(observation("ast", x: 507.5, positioned: false))
        sampler.observe(observation("asth", x: 515, positioned: false))
        XCTAssertNil(sampler.sample)
        // A positioned caret after an estimated one starts fresh rather than pairing with it.
        sampler.observe(observation("asthe", x: 522.5))
        XCTAssertNil(sampler.sample)
    }

    func testABackspaceOrACaretMoveStartsOver() {
        var sampler = CaretAdvanceSampler()
        let x = typed("the user writes", after: "as", from: 500, advance: 7.5, into: &sampler)
        XCTAssertNotNil(sampler.sample)
        sampler.observe(observation("asthe user write", x: x - 7.5))
        XCTAssertNil(sampler.sample, "a backspace is not typing")
        _ = typed("s well, and so", after: "asthe user write", from: x - 7.5, advance: 7.5, into: &sampler)
        XCTAssertEqual(sampler.sample?.text, "s well, and so", "the new run is measured on its own")
    }

    func testANewLineStartsOver() {
        var sampler = CaretAdvanceSampler()
        _ = typed("the user writes", after: "as", from: 500, advance: 7.5, into: &sampler)
        // Enter: the caret drops to the next line and returns to the left edge.
        sampler.observe(observation("asthe user writes\n", x: 100, y: 80))
        sampler.observe(observation("asthe user writes\nA", x: 107.5, y: 80))
        XCTAssertNil(sampler.sample)
    }

    func testAPastedBlockIsNotAKeystroke() {
        var sampler = CaretAdvanceSampler()
        sampler.observe(observation("as", x: 500))
        sampler.observe(observation("as the user writes and then", x: 700))
        XCTAssertNil(sampler.sample)
    }

    func testASlidTextWindowStillReadsAsTyping() {
        // The snapshot carries only a bounded tail of the text; as it slides the old characters
        // fall off the front while the document caret keeps counting.
        var sampler = CaretAdvanceSampler()
        let window = String(repeating: "x", count: 40)
        var text = window
        var caret = 4000
        var x: CGFloat = 500
        sampler.observe(observation(text, x: x, caret: caret))
        for character in "the user writes" {
            text = String((text + String(character)).suffix(40))
            caret += 1
            x += 7.5
            sampler.observe(observation(text, x: x, caret: caret))
        }
        XCTAssertEqual(sampler.sample?.text, "the user writes")
    }

    func testChromiumsNonBreakingLineEndSpaceDoesNotBreakTheRun() {
        // Chromium stores the space typed at the end of a line as U+00A0 and turns it back into a
        // plain space when the next letter arrives; both polls describe the same typing.
        var sampler = CaretAdvanceSampler()
        sampler.observe(observation("asthe", x: 500))
        sampler.observe(observation("asthe\u{00A0}", x: 503.8))
        sampler.observe(observation("asthe user", x: 503.8 + 7.5 * 4))
        sampler.observe(observation("asthe user\u{00A0}", x: 503.8 + 7.5 * 4 + 3.8))
        sampler.observe(observation("asthe user writes", x: 500 + 3.8 * 2 + 7.5 * 10))
        XCTAssertEqual(sampler.sample?.text, " user writes")
        XCTAssertEqual(sampler.sample?.width ?? 0, 3.8 * 2 + 7.5 * 10, accuracy: 0.001)
    }

    func testOldChunksFallOffOnceTheSampleIsLongEnough() {
        var sampler = CaretAdvanceSampler()
        let long = "the quick brown fox jumps over the lazy dog again"
        _ = typed(long, after: "", from: 100, advance: 7.5, into: &sampler)
        let sample = sampler.sample
        XCTAssertEqual(sample?.text.count, CaretAdvanceSampler.maximumLength)
        XCTAssertEqual(sample?.text, String(long.suffix(CaretAdvanceSampler.maximumLength)))
        XCTAssertEqual(sample?.width ?? 0, 7.5 * CGFloat(CaretAdvanceSampler.maximumLength), accuracy: 0.001)
    }
}
