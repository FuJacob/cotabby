import AppKit
import XCTest
@testable import Cotabby

/// Tests for the overlay value models the coordinator hands to the presentation layer.
final class SuggestionPresentationModelsTests: XCTestCase {
    private static let hostMetrics = HostTextMetrics(
        sampleText: "Keep on veri",
        sampleWidth: 89,
        lineRect: CGRect(x: 4, y: 18, width: 200, height: 22),
        linePitch: 24,
        lineRectIsFromTextMarkers: true,
        linePitchIsFromParagraphBox: true
    )

    /// A geometry with every field away from its default. Both copy helpers rebuild the value one
    /// field at a time, so expected copies are built through this same function, overriding only
    /// what a helper is meant to change: a field a helper drops by omission then fails the equality.
    private func populatedGeometry(
        caretRect: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18),
        caretQuality: CaretGeometryQuality = .layoutEstimated,
        hostTextMetrics: HostTextMetrics? = SuggestionPresentationModelsTests.hostMetrics,
        pixelBaselineOffset: CGFloat? = 14,
        pixelLineInkWidth: CGFloat? = 180,
        isCaretLineVerticallyUncalibrated: Bool = true
    ) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: CGRect(x: 0, y: 0, width: 240, height: 32),
            caretQuality: caretQuality,
            bundleIdentifier: "com.example.host",
            focusedURLString: "https://docs.example/one",
            isCaretAtEndOfLine: false,
            observedCharWidth: 7,
            isRightToLeft: true,
            focusChangeSequence: 9,
            focusedInputIdentityKey: 77,
            isCorrection: true,
            resolvedFieldStyle: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 13, colorHex: "336699"),
            hostTextMetrics: hostTextMetrics,
            isWebContentField: true,
            hasTrailingContent: true,
            isSingleLineField: true,
            elementFrameRect: CGRect(x: 0, y: 2, width: 236, height: 28),
            lineTextBeforeCaret: "Keep on veri",
            wrappedRun: WrappedRunAnchor(
                frame: CGRect(x: 4, y: 18, width: 200, height: 44), paragraphTextBeforeCaret: "Keep on veri"
            ),
            pixelBaselineOffset: pixelBaselineOffset,
            pixelLineInkWidth: pixelLineInkWidth,
            observedContentEdges: ObservedContentEdges(leftX: 4, topY: 30, isRunMeasured: true),
            isCaretLineVerticallyUncalibrated: isCaretLineVerticallyUncalibrated
        )
    }

    /// Word acceptance slides the caret by a measured width. Everything describing the field carries
    /// over; the pixel baseline and line ink width belong to the pixel-measured caret the geometry
    /// carried (nil for every other caret), so the advanced caret drops them.
    func test_overlayGeometry_withCaretRectKeepsTheFieldButDropsThePixelCaretReadings() {
        let advancedCaret = CGRect(x: 52, y: 20, width: 2, height: 18)

        let advanced = populatedGeometry().withCaretRect(advancedCaret)

        XCTAssertEqual(
            advanced,
            populatedGeometry(caretRect: advancedCaret, pixelBaselineOffset: nil, pixelLineInkWidth: nil)
        )
    }

    /// A caret measured from the host's pixels is a real measurement: it is trusted as `.derived`,
    /// its line is no longer a vertical guess, and its line box and pitch replace the host's while
    /// the host's typeface sample is kept. A pixel line box never came from text markers.
    func test_overlayGeometry_withPixelMeasuredCaretTrustsTheMeasurementAndCarriesItsLine() {
        let caret = CGRect(x: 120, y: 40, width: 1, height: 17)
        let line = CGRect(x: 6, y: 38, width: 300, height: 21)

        let measured = populatedGeometry().withPixelMeasuredCaret(
            caret, lineRect: line, linePitch: 26, baselineOffsetFromTop: 13, lineInkWidth: 210
        )

        XCTAssertEqual(measured, populatedGeometry(
            caretRect: caret,
            caretQuality: .derived,
            hostTextMetrics: HostTextMetrics(sampleText: "Keep on veri", sampleWidth: 89, lineRect: line, linePitch: 26),
            pixelBaselineOffset: 13,
            pixelLineInkWidth: 210,
            isCaretLineVerticallyUncalibrated: false
        ))
    }

    /// Without a pitch of its own the pixel read keeps the host's, along with where that pitch came
    /// from; without a baseline or ink reading the earlier caret's readings are not kept either.
    func test_overlayGeometry_withPixelMeasuredCaretFallsBackToTheHostsPitch() {
        let caret = CGRect(x: 120, y: 40, width: 1, height: 17)
        let line = CGRect(x: 6, y: 38, width: 300, height: 21)

        let measured = populatedGeometry().withPixelMeasuredCaret(caret, lineRect: line, linePitch: nil)

        XCTAssertEqual(measured.hostTextMetrics, HostTextMetrics(
            sampleText: "Keep on veri", sampleWidth: 89, lineRect: line, linePitch: 24, linePitchIsFromParagraphBox: true
        ))
        XCTAssertNil(measured.pixelBaselineOffset)
        XCTAssertNil(measured.pixelLineInkWidth)

        let unmeasuredHost = populatedGeometry(hostTextMetrics: nil)
            .withPixelMeasuredCaret(caret, lineRect: line, linePitch: nil)
        XCTAssertEqual(unmeasuredHost.hostTextMetrics, HostTextMetrics(lineRect: line))
    }

    func test_overlayState_isVisibleInEitherRenderModeAndNotWhenHidden() {
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .derived)
        XCTAssertTrue(OverlayState.visible(text: "hello", geometry: geometry, mode: .inline).isVisible)
        XCTAssertTrue(
            OverlayState.visible(text: "hello", geometry: geometry, mode: .mirror(reason: .caretMidLine)).isVisible
        )
        XCTAssertFalse(OverlayState.hidden(reason: "No suggestion buffered").isVisible)
    }
}
