import CoreGraphics
import XCTest
@testable import Cotabby

/// The user's floor and ceiling bound whatever size the host's font resolution produced, and no
/// ghost is drawn below the legibility backstop, whatever the host or the user asks for.
final class GhostFontSizeLimitsTests: XCTestCase {
    private let backstop = GhostFontSizeLimits.absoluteMinimumPointSize

    func test_clamped_holdsTheSizeInsideTheUsersRange() {
        XCTAssertEqual(GhostFontSizeLimits.clamped(13, floor: 11, ceiling: 48), 13)
        XCTAssertEqual(GhostFontSizeLimits.clamped(6, floor: 11, ceiling: 48), 11)
        XCTAssertEqual(GhostFontSizeLimits.clamped(72, floor: 11, ceiling: 48), 48)
    }

    /// Matching the host's own text size passes zero for both limits, which sets them aside and
    /// leaves only the backstop.
    func test_clamped_zeroLimitsLeaveOnlyTheLegibilityBackstop() {
        XCTAssertEqual(GhostFontSizeLimits.clamped(72, floor: 0, ceiling: 0), 72)
        XCTAssertEqual(GhostFontSizeLimits.clamped(6, floor: 0, ceiling: 0), backstop)
    }

    /// The backstop is applied last, so neither a host's tiny size nor a user limit below it wins.
    func test_clamped_backstopOutranksLimitsBelowIt() {
        XCTAssertEqual(GhostFontSizeLimits.clamped(6, floor: backstop - 2, ceiling: 48), backstop)
        XCTAssertEqual(GhostFontSizeLimits.clamped(13, floor: 0, ceiling: backstop - 4), backstop)
    }

    /// Settings keep the floor at or below the ceiling and repair an inverted pair on load, but if
    /// one ever arrives here the ceiling is applied first and the floor last, so the floor wins.
    func test_clamped_invertedRangeLetsTheFloorWin() {
        XCTAssertEqual(GhostFontSizeLimits.clamped(20, floor: 40, ceiling: 16), 40)
        XCTAssertEqual(GhostFontSizeLimits.clamped(50, floor: 40, ceiling: 16), 40)
    }
}
