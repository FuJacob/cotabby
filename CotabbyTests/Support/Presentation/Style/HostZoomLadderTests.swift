import XCTest
@testable import Cotabby

/// Each case is a size measured from a host's pixels (2026-09-11) against the size it reports.
final class HostZoomLadderTests: XCTestCase {
    private func snapped(_ measured: CGFloat, _ reported: CGFloat, _ kind: HostZoomLadder.Kind) -> CGFloat? {
        HostZoomLadder.snappedSize(measured: measured, reported: reported, kind: kind)
    }

    /// Claude's config.json: `windowControlsZoomFactor` 1.0954451150103321, Electron level 0.5.
    func testClaudesComposerPaintsAtElectronsHalfLevel() throws {
        let size = try XCTUnwrap(snapped(15.4, 14, .electron))
        XCTAssertEqual(size, 14 * 1.0954451150103321, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapped(15.30, 14, .electron)), 15.336, accuracy: 0.001)
    }

    func testAMeasurementNearTheReportedSizeIsTheReportedSize() {
        XCTAssertEqual(snapped(16.096, 16, .electron), 16, "Obsidian's system text, matched 0.6% wide")
        XCTAssertEqual(snapped(15.992, 16, .electron), 16)
        XCTAssertEqual(snapped(14.91, 15, .chromeBrowser), 15, "a Chrome contenteditable at 100%")
    }

    func testChromeZoomsThroughItsPresets() throws {
        XCTAssertEqual(try XCTUnwrap(snapped(15.37, 14, .chromeBrowser)), 15.4, accuracy: 0.0001, "110%")
        XCTAssertEqual(try XCTUnwrap(snapped(17.4, 14, .chromeBrowser)), 17.5, accuracy: 0.0001, "125%")
    }

    func testAMeasurementBetweenStepsKeepsItsOwnSize() {
        XCTAssertNil(snapped(15.0, 14, .electron), "7% over: between level 0 and level 0.5")
        XCTAssertNil(snapped(24, 16, .electron), "a heading at 1.5 times the base size sits between Electron's steps")
        XCTAssertEqual(snapped(24, 16, .chromeBrowser), 24, "150% is one of Chrome's own presets: the size stays")
        XCTAssertNil(snapped(20.8, 16, .electron), "1.3 is 1.1% from level 1.5")
    }

    func testDegenerateInputsSnapNothing() {
        XCTAssertNil(snapped(0, 14, .electron))
        XCTAssertNil(snapped(15, 0, .chromeBrowser))
        XCTAssertNil(snapped(.infinity, 14, .electron))
    }
}
