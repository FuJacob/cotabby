import XCTest
@testable import Cotabby

@MainActor
final class HostBaselineCalibratorTests: XCTestCase {
    func testCaptureStripSitsLeftOfTheCaretAndInsideTheContent() {
        let caret = CGRect(x: 340, y: 809, width: 0, height: 15)
        let strip = HostBaselineCalibrator.captureStrip(caretRect: caret, contentLeft: 97)
        XCTAssertEqual(strip, CGRect(x: 98, y: 807, width: 240, height: 19))
        let narrow = HostBaselineCalibrator.captureStrip(caretRect: caret, contentLeft: 330)
        XCTAssertNil(narrow, "Ten points of text is not enough to measure")
        let unbounded = HostBaselineCalibrator.captureStrip(caretRect: caret, contentLeft: nil)
        XCTAssertEqual(unbounded?.minX, 340 - 2 - HostBaselineCalibrator.maximumStripWidth)
    }

    func testMeasuredBaselineIsExpressedBelowTheCaretTop() {
        // Strip top 2pt above the caret top; text baseline measured 13.5pt below the strip top.
        let offset = HostBaselineCalibrator.baselineOffset(fromCaretTop: 824, stripTop: 826, measured: 13.5)
        XCTAssertEqual(offset, 11.5)
    }

    func testOnlySmallCorrectionsAreAccepted() {
        XCTAssertTrue(HostBaselineCalibrator.accepts(measured: 11.5, policy: 12))
        XCTAssertTrue(HostBaselineCalibrator.accepts(measured: 14.5, policy: 14))
        // Safari, Georgia 18px contenteditable at line-height 1.6: policy 20.5, painted baseline 24.
        XCTAssertTrue(HostBaselineCalibrator.accepts(measured: 24, policy: 20.5))
        XCTAssertFalse(HostBaselineCalibrator.accepts(measured: 26, policy: 20.5), "A neighbouring line is not this baseline")
    }

    func testWithoutScreenRecordingNothingIsCapturedOrCached() {
        let calibrator = HostBaselineCalibrator(permissionCheck: { false })
        let key = HostBaselineCalibrator.Key(focusedInputIdentityKey: 1, lineTop: 824, caretHeight: 15, fontPointSize: 13)
        var completions = 0
        calibrator.calibrate(
            HostBaselineCalibrator.Request(
                key: key, caretRect: CGRect(x: 340, y: 809, width: 0, height: 15), contentLeft: 97, policyOffset: 12
            )
        ) { _ in completions += 1 }
        XCTAssertNil(calibrator.cachedOffset(for: key))
        XCTAssertEqual(completions, 0)
    }
}
