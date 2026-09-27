import XCTest
@testable import Cotabby

final class TypingCadenceTests: XCTestCase {
    func testDisplayWaitsThroughBriefHesitationButNotAWordBoundary() {
        var cadence = TypingCadence()
        for (index, letter) in ["s", "c", "h", "e"].enumerated() {
            cadence.record(identityKey: 1, characters: letter, at: Double(index) * 0.1)
        }
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "sche", at: 0.32), 0.1, accuracy: 0.001)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "sche", at: 0.5), 0)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 2, precedingText: "sche", at: 0.32), 0)
        cadence.record(identityKey: 1, characters: " ", at: 0.33)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "schedule ", at: 0.34), 0)
    }

    func testQuietWindowTracksMedianRhythmWithinItsBounds() {
        // Slow but steady typing (500ms gaps) would ask for 600ms; the window is capped at 220ms.
        var slow = TypingCadence()
        for (index, letter) in ["a", "b", "c"].enumerated() {
            slow.record(identityKey: 1, characters: letter, at: Double(index) * 0.5)
        }
        XCTAssertEqual(slow.remainingDelay(identityKey: 1, precedingText: "abc", at: 1.0), 0.22, accuracy: 0.001)

        // Very fast typing (30ms gaps) would ask for 36ms; the window never drops below 80ms.
        var fast = TypingCadence()
        for (index, letter) in ["a", "b", "c"].enumerated() {
            fast.record(identityKey: 1, characters: letter, at: Double(index) * 0.03)
        }
        XCTAssertEqual(fast.remainingDelay(identityKey: 1, precedingText: "abc", at: 0.06), 0.08, accuracy: 0.001)
    }

    func testSwitchingFieldsDiscardsThePreviousFieldsRhythm() {
        var cadence = TypingCadence()
        for (index, letter) in ["a", "b", "c"].enumerated() {
            cadence.record(identityKey: 1, characters: letter, at: Double(index) * 0.5)
        }
        cadence.record(identityKey: 2, characters: "x", at: 1.1)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "abc", at: 1.1), 0)
        // The new field starts without intervals, so only the default brief-hesitation window applies.
        XCTAssertEqual(cadence.remainingDelay(identityKey: 2, precedingText: "x", at: 1.1), 0.08, accuracy: 0.001)
    }

    func testNonFiniteTimestampsAreIgnoredAndNonWordPrefixesPayNoDelay() {
        var cadence = TypingCadence()
        cadence.record(identityKey: 1, characters: "a", at: .nan)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "a", at: 0), 0,
                       "a NaN timestamp must not even claim the field identity")
        cadence.record(identityKey: 1, characters: "a", at: 0)
        for prefix in ["", "call(wor", "你好", "item2"] {
            XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: prefix, at: 0.01), 0, prefix)
        }
    }

    func testLongPauseAndPasteDoNotBecomeTypingRhythm() {
        var cadence = TypingCadence()
        cadence.record(identityKey: 1, characters: "s", at: 0)
        cadence.record(identityKey: 1, characters: "c", at: 5)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "sc", at: 5), 0.08, accuracy: 0.001)
        cadence.record(identityKey: 1, characters: "pasted", at: 5.01)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "pasted", at: 5.02), 0)
    }
}
