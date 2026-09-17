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

    func testLongPauseAndPasteDoNotBecomeTypingRhythm() {
        var cadence = TypingCadence()
        cadence.record(identityKey: 1, characters: "s", at: 0)
        cadence.record(identityKey: 1, characters: "c", at: 5)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "sc", at: 5), 0.08, accuracy: 0.001)
        cadence.record(identityKey: 1, characters: "pasted", at: 5.01)
        XCTAssertEqual(cadence.remainingDelay(identityKey: 1, precedingText: "pasted", at: 5.02), 0)
    }
}
