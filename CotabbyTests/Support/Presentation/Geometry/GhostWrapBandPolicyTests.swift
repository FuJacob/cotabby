import XCTest
@testable import Cotabby

final class GhostWrapBandPolicyTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// Measured live in TextEdit: element frame 200...620, line box starting at 205, widened input
    /// frame 150...711. The band must follow the element and its 5pt padding, not the widened frame.
    func testBandUsesTheElementFrameAndTheMeasuredPaddingOnBothSides() {
        let band = GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: CGRect(x: 567.4, y: 300, width: 0, height: 16),
                elementFrame: CGRect(x: 200, y: 300, width: 420, height: 194),
                inputFrame: CGRect(x: 150, y: 300, width: 561, height: 194),
                lineLeft: 205,
                screenVisibleFrame: screen
            )
        )
        XCTAssertEqual(band.lowerBound, 205, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 615, accuracy: 0.001)
    }

    func testWithoutALineBoxTheDefaultInsetIsAssumedOnBothSides() {
        let band = GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: CGRect(x: 300, y: 300, width: 1, height: 18),
                elementFrame: CGRect(x: 100, y: 200, width: 500, height: 100),
                inputFrame: CGRect(x: 100, y: 200, width: 900, height: 100),
                lineLeft: nil,
                screenVisibleFrame: screen
            )
        )
        XCTAssertEqual(band.lowerBound, 104, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 596, accuracy: 0.001)
    }

    func testAnImplausibleLineLeftStillAnchorsTheLeftEdgeButNotTheRightInset() {
        // A line box 300pt inside its element is not padding (a centered page, say); the right
        // edge falls back to the default inset instead of shrinking the band by 300pt.
        let band = GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: CGRect(x: 500, y: 300, width: 1, height: 18),
                elementFrame: CGRect(x: 100, y: 200, width: 800, height: 100),
                inputFrame: nil,
                lineLeft: 400,
                screenVisibleFrame: screen
            )
        )
        XCTAssertEqual(band.lowerBound, 400, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 896, accuracy: 0.001)
    }

    func testWidenedInputFrameIsOnlyALastResort() {
        let band = GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: CGRect(x: 300, y: 300, width: 1, height: 18),
                elementFrame: nil,
                inputFrame: CGRect(x: 100, y: 200, width: 500, height: 100),
                lineLeft: nil,
                screenVisibleFrame: screen
            )
        )
        XCTAssertEqual(band.lowerBound, 104, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 596, accuracy: 0.001)
    }

    func testBandIsClampedToTheScreen() {
        let band = GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: CGRect(x: 1400, y: 300, width: 1, height: 18),
                elementFrame: CGRect(x: 1300, y: 200, width: 600, height: 100),
                inputFrame: nil,
                lineLeft: nil,
                screenVisibleFrame: screen
            )
        )
        XCTAssertEqual(band.lowerBound, 1304, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 1504, accuracy: 0.001)
    }

    func testNoFramesAtAllStartsRowsAtTheCaretAndEndsAtTheScreen() {
        let band = GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: CGRect(x: 640, y: 300, width: 1, height: 18),
                elementFrame: nil,
                inputFrame: nil,
                lineLeft: nil,
                screenVisibleFrame: screen
            )
        )
        XCTAssertEqual(band.lowerBound, 640, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 1504, accuracy: 0.001)
    }
}
