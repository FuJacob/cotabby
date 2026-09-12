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

    // MARK: - Measurement plausibility

    private func measurement(bodyTop: Int, baseline: Int) -> InkBaselineAnalyzer.Measurement {
        InkBaselineAnalyzer.Measurement(baselineRow: baseline, bodyTopRow: bodyTop, inkPixelCount: 400)
    }

    /// Ordinary prose at 17pt on a 2x display: bodies run about the font's ascent.
    func testBodiesTheSizeOfTheFontsAscentAreBelievable() {
        let ascent = Int((NSFont.systemFont(ofSize: 17).ascender * 2).rounded())
        XCTAssertTrue(HostBaselineCalibrator.describesPlausibleBodies(
            measurement(bodyTop: 4, baseline: 4 + ascent), pointSize: 17, scale: 2
        ))
    }

    /// An all-x-height line has shorter bodies and must still be accepted.
    func testShortButRealBodiesAreStillBelievable() {
        let ascent = NSFont.systemFont(ofSize: 17).ascender * 2
        let rows = Int((ascent * 0.55).rounded())
        XCTAssertTrue(HostBaselineCalibrator.describesPlausibleBodies(
            measurement(bodyTop: 6, baseline: 6 + rows), pointSize: 17, scale: 2
        ))
    }

    /// The failure that put ghost text visibly high on some lines: the strip caught a fragment, so
    /// the "bodies" are a few pixels tall and the baseline read from them is confidently wrong.
    func testAFragmentTooSmallToBeALineIsRejected() {
        XCTAssertFalse(HostBaselineCalibrator.describesPlausibleBodies(
            measurement(bodyTop: 10, baseline: 14), pointSize: 17, scale: 2
        ))
    }

    /// Two lines merged into one block (a strip that caught the line below) measure far too tall.
    func testABlockTallerThanTheFontIsRejected() {
        let ascent = NSFont.systemFont(ofSize: 17).ascender * 2
        let rows = Int((ascent * 2).rounded())
        XCTAssertFalse(HostBaselineCalibrator.describesPlausibleBodies(
            measurement(bodyTop: 2, baseline: 2 + rows), pointSize: 17, scale: 2
        ))
    }

    func testUnknownFontSizeLeavesTheMeasurementAlone() {
        XCTAssertTrue(HostBaselineCalibrator.describesPlausibleBodies(
            measurement(bodyTop: 10, baseline: 14), pointSize: 0, scale: 2
        ))
    }
}
