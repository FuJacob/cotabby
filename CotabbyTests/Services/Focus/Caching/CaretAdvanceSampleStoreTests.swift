import XCTest
@testable import Cotabby

/// The store keeps one `CaretAdvanceSampler` for the focused field across polls. Its one rule of
/// its own: a poll for another field never continues the previous field's sample, because the two
/// carets' movement says nothing about each other's glyphs.
@MainActor
final class CaretAdvanceSampleStoreTests: XCTestCase {
    private func observation(_ text: String, x: CGFloat) -> CaretAdvanceSampler.Observation {
        CaretAdvanceSampler.Observation(
            caretX: x, lineY: 100, documentCaret: text.count, precedingText: text, isPositioned: true
        )
    }

    /// Types `text` after `prefix` into the field `key`, one character per poll at 7.5pt each, and
    /// returns the sample after the last poll.
    @discardableResult
    private func typeText(
        _ text: String, after prefix: String, from x: CGFloat, key: String, into store: CaretAdvanceSampleStore
    ) -> CaretAdvanceSampler.Sample? {
        var current = prefix
        var caretX = x
        var sample = store.sample(forKey: key, observation: observation(current, x: caretX))
        for character in text {
            current.append(character)
            caretX += 7.5
            sample = store.sample(forKey: key, observation: observation(current, x: caretX))
        }
        return sample
    }

    func test_pollsOfOneFieldAccumulateIntoOneSample() {
        let store = CaretAdvanceSampleStore()

        let sample = typeText("the user writes", after: "as", from: 500, key: "field-a", into: store)

        XCTAssertEqual(sample?.text, "the user writes")
        XCTAssertEqual(sample?.width ?? 0, 7.5 * 15, accuracy: 0.001)
    }

    /// The same caret one keystroke on, but reported for another field, starts that field's
    /// sampler from nothing; returning to the first field starts over too, since only the current
    /// field is kept.
    func test_anotherFieldNeverContinuesTheSample() {
        let store = CaretAdvanceSampleStore()
        XCTAssertNotNil(typeText("the user writes", after: "as", from: 500, key: "field-a", into: store))
        let endX: CGFloat = 500 + 7.5 * 15

        XCTAssertNil(store.sample(forKey: "field-b", observation: observation("asthe user writes!", x: endX + 7.5)))
        XCTAssertNil(store.sample(forKey: "field-a", observation: observation("asthe user writes!?", x: endX + 15)))
    }
}
