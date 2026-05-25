import CoreGraphics
import XCTest
@testable import Cotabby

final class GhostFontSizeStabilizerTests: XCTestCase {

    func test_firstReadingEstablishesBaseline() {
        var stabilizer = GhostFontSizeStabilizer()
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(18, focusSessionKey: 1), 18)
    }

    func test_largerReadingInSameSessionClampsToMinimum() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(18, focusSessionKey: 1)
        // A later poll falls back to the full field height; we keep the smaller real line height.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(120, focusSessionKey: 1), 18)
    }

    func test_smallerReadingLowersMinimumForRestOfSession() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(40, focusSessionKey: 7)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(22, focusSessionKey: 7), 22)
        // The new lower floor sticks even when a tall reading returns later in the session.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(90, focusSessionKey: 7), 22)
    }

    func test_sessionChangeResetsBaseline() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(16, focusSessionKey: 1)
        // Switching fields must not pin a tall field to the previous field's short line height.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(48, focusSessionKey: 2), 48)
    }

    func test_reentryWithNewSessionKeyResetsEvenWhenLarger() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(18, focusSessionKey: 3)
        _ = stabilizer.stabilizedCaretHeight(18, focusSessionKey: 3)
        // focusChangeSequence increments on focus loss + re-entry, so the larger reading is honored.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(30, focusSessionKey: 4), 30)
    }

    func test_nonPositiveHeightPassesThroughWithoutPoisoningCache() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(20, focusSessionKey: 5)
        // A transient empty rect should not become the session minimum.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(0, focusSessionKey: 5), 0)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(20, focusSessionKey: 5), 20)
    }

    func test_genuinelyLargeFieldStaysLarge() {
        var stabilizer = GhostFontSizeStabilizer()
        // Every poll agrees the line is tall; nothing should shrink it.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(60, focusSessionKey: 9), 60)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(60, focusSessionKey: 9), 60)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(62, focusSessionKey: 9), 60)
    }
}
