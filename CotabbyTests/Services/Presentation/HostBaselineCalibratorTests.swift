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

    func testBackgroundRegionCoversTheCaretLineAndTheLineBelowInsideTheField() {
        let caret = CGRect(x: 340, y: 809, width: 0, height: 15)
        let region = HostBaselineCalibrator.backgroundRegion(
            HostBaselineCalibrator.BackgroundRequest(
                focusedInputIdentityKey: 1, caretRect: caret, linePitch: 20, contentLeft: 300, contentRight: 900, contentBottom: 700
            )
        )
        XCTAssertEqual(region, CGRect(x: 300, y: 789, width: 160, height: 35))

        let lastLine = HostBaselineCalibrator.backgroundRegion(
            HostBaselineCalibrator.BackgroundRequest(
                focusedInputIdentityKey: 1, caretRect: caret, linePitch: 20, contentLeft: nil, contentRight: nil, contentBottom: 805
            )
        )
        XCTAssertEqual(lastLine, CGRect(x: 220, y: 805, width: 240, height: 19), "the field's bottom edge bounds the region")

        let narrow = HostBaselineCalibrator.backgroundRegion(
            HostBaselineCalibrator.BackgroundRequest(
                focusedInputIdentityKey: 1, caretRect: caret, linePitch: nil, contentLeft: 335, contentRight: 345, contentBottom: nil
            )
        )
        XCTAssertNil(narrow)
    }

    func testBackgroundSamplingSplitsTheCaretLineFromTheLineBelow() throws {
        // 4x6 bitmap: the caret line (rows 0-2) is a tinted gray with one dark "glyph" pixel per row;
        // the line below (rows 3-5) is white.
        var bytes: [UInt8] = []
        for row in 0..<6 {
            for column in 0..<4 {
                let isGlyph = row < 3 && column == 1
                let value: UInt8 = row < 3 ? (isGlyph ? 20 : 235) : 255
                bytes += [value, value, value, 255]
            }
        }
        let bitmap = RGBABitmap(width: 4, height: 6, bytes: bytes)
        let background = try XCTUnwrap(HostBaselineCalibrator.sampleBackground(bitmap, caretLineRows: 3))
        XCTAssertEqual(background.caretLine, RGBABitmap.Pixel(red: 235 / 255, green: 235 / 255, blue: 235 / 255))
        XCTAssertEqual(background.nextLine, RGBABitmap.Pixel(red: 1, green: 1, blue: 1))

        let caretOnly = try XCTUnwrap(HostBaselineCalibrator.sampleBackground(bitmap, caretLineRows: 6))
        XCTAssertEqual(caretOnly.nextLine, caretOnly.caretLine, "no pixels below the caret line: the caret line's color stands in")
    }

    func testWithoutScreenRecordingNothingIsMeasured() {
        let calibrator = HostBaselineCalibrator(permissionCheck: { false })
        var completions = 0
        calibrator.measureBackground(
            HostBaselineCalibrator.BackgroundRequest(
                focusedInputIdentityKey: 7, caretRect: CGRect(x: 340, y: 809, width: 0, height: 15),
                linePitch: nil, contentLeft: nil, contentRight: nil, contentBottom: nil
            )
        ) { _ in completions += 1 }
        XCTAssertNil(calibrator.cachedBackground(for: 7))
        XCTAssertEqual(completions, 0)
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
