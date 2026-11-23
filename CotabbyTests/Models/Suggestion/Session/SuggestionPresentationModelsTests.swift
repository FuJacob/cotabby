import AppKit
import XCTest
@testable import Cotabby

/// Tests for the overlay value models the coordinator hands to the presentation layer.
final class SuggestionPresentationModelsTests: XCTestCase {
    func test_overlayGeometry_withCaretRectReplacesOnlyTheCaretRect() {
        let style = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 13, colorHex: "336699")
        let edges = ObservedContentEdges(leftX: 4, topY: 30, isRunMeasured: true)
        let original = SuggestionOverlayGeometry(
            caretRect: CGRect(x: 10, y: 20, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 0, width: 240, height: 32),
            caretQuality: .derived,
            bundleIdentifier: "com.example.host",
            isCaretAtEndOfLine: false,
            observedCharWidth: 7,
            isRightToLeft: true,
            focusChangeSequence: 9,
            focusedInputIdentityKey: 77,
            resolvedFieldStyle: style,
            observedContentEdges: edges
        )

        let advanced = original.withCaretRect(CGRect(x: 52, y: 20, width: 2, height: 18))

        XCTAssertEqual(advanced.caretRect, CGRect(x: 52, y: 20, width: 2, height: 18))
        XCTAssertEqual(advanced.inputFrameRect, original.inputFrameRect)
        XCTAssertEqual(advanced.caretQuality, .derived)
        XCTAssertEqual(advanced.bundleIdentifier, "com.example.host")
        XCTAssertFalse(advanced.isCaretAtEndOfLine)
        XCTAssertEqual(advanced.observedCharWidth, 7)
        XCTAssertTrue(advanced.isRightToLeft)
        XCTAssertEqual(advanced.focusChangeSequence, 9)
        XCTAssertEqual(advanced.focusedInputIdentityKey, 77)
        XCTAssertEqual(advanced.resolvedFieldStyle, style)
        XCTAssertEqual(advanced.observedContentEdges, edges)
    }

    func test_overlayState_visibleExposesRenderModeAndHiddenExposesNone() {
        let visible = OverlayState.visible(
            text: "hello",
            geometry: CotabbyTestFixtures.overlayGeometry(caretQuality: .derived),
            mode: .mirror(reason: .caretMidLine)
        )
        XCTAssertTrue(visible.isVisible)
        XCTAssertEqual(visible.visibleMode, .mirror(reason: .caretMidLine))

        let hidden = OverlayState.hidden(reason: "No suggestion buffered")
        XCTAssertFalse(hidden.isVisible)
        XCTAssertNil(hidden.visibleMode)
    }
}
