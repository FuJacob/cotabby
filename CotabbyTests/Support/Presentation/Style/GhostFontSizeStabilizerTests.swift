import CoreGraphics
import XCTest
@testable import Cotabby

final class GhostFontSizeStabilizerTests: XCTestCase {

    func test_firstReadingEstablishesBaseline() {
        var stabilizer = GhostFontSizeStabilizer()
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(18, isPreciseMeasurement: false, focusSessionKey: 1), 18)
    }

    func test_largerReadingInSameSessionClampsToMinimum() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(18, isPreciseMeasurement: false, focusSessionKey: 1)
        // A later poll falls back to the full field height; we keep the smaller real line height.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(120, isPreciseMeasurement: false, focusSessionKey: 1), 18)
    }

    func test_smallerReadingLowersMinimumForRestOfSession() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(40, isPreciseMeasurement: false, focusSessionKey: 7)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(22, isPreciseMeasurement: false, focusSessionKey: 7), 22)
        // The new lower floor sticks even when a tall reading returns later in the session.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(90, isPreciseMeasurement: false, focusSessionKey: 7), 22)
    }

    func test_sessionChangeResetsBaseline() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(16, isPreciseMeasurement: false, focusSessionKey: 1)
        // Switching fields must not pin a tall field to the previous field's short line height.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(48, isPreciseMeasurement: false, focusSessionKey: 2), 48)
    }

    func test_reentryWithNewSessionKeyResetsEvenWhenLarger() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(18, isPreciseMeasurement: false, focusSessionKey: 3)
        _ = stabilizer.stabilizedCaretHeight(18, isPreciseMeasurement: false, focusSessionKey: 3)
        // focusChangeSequence increments on focus loss + re-entry, so the larger reading is honored.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(30, isPreciseMeasurement: false, focusSessionKey: 4), 30)
    }

    func test_nonPositiveHeightPassesThroughWithoutPoisoningCache() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(20, isPreciseMeasurement: false, focusSessionKey: 5)
        // A transient empty rect should not become the session minimum.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(0, isPreciseMeasurement: false, focusSessionKey: 5), 0)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(20, isPreciseMeasurement: false, focusSessionKey: 5), 20)
    }

    func test_genuinelyLargeFieldStaysLarge() {
        var stabilizer = GhostFontSizeStabilizer()
        // Every poll agrees the line is tall; nothing should shrink it.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(60, isPreciseMeasurement: false, focusSessionKey: 9), 60)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(60, isPreciseMeasurement: false, focusSessionKey: 9), 60)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(62, isPreciseMeasurement: false, focusSessionKey: 9), 60)
    }

    // MARK: - Precise readings must not be ratcheted

    /// The bug this guards: a user typing in Word at 12pt then switching the document to 20pt kept
    /// a caret height pinned to the old session minimum, so ghost text stayed ~40% too small until
    /// focus happened to change. Font size and zoom both grow the line box without changing fields.
    func test_preciseReadingIsHonoredEvenWhenLargerThanSessionMinimum() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(23, isPreciseMeasurement: true, focusSessionKey: 1)
        _ = stabilizer.stabilizedCaretHeight(17, isPreciseMeasurement: true, focusSessionKey: 1)
        // Document restyled to 20pt inside the same field: the new, larger measurement wins.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(28, isPreciseMeasurement: true, focusSessionKey: 1), 28)
    }

    func test_preciseReadingResetsBaselineForLaterImpreciseReadings() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(17, isPreciseMeasurement: true, focusSessionKey: 1)
        _ = stabilizer.stabilizedCaretHeight(28, isPreciseMeasurement: true, focusSessionKey: 1)
        // A coarse AXFrame fallback afterwards is still clamped — but to the *current* truth (28),
        // not the stale 17, so the flicker protection survives without the ratchet.
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(400, isPreciseMeasurement: false, focusSessionKey: 1), 28)
    }

    func test_impreciseReadingStillClampsToMinimum() {
        var stabilizer = GhostFontSizeStabilizer()
        _ = stabilizer.stabilizedCaretHeight(18, isPreciseMeasurement: false, focusSessionKey: 1)
        XCTAssertEqual(stabilizer.stabilizedCaretHeight(846, isPreciseMeasurement: false, focusSessionKey: 1), 18)
    }
}
