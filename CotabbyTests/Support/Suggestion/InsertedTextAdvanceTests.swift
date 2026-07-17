import AppKit
import XCTest
@testable import Cotabby

/// Locks the host-font caret-travel measurement that keeps the accept-time overlay slide aligned
/// with where AX will report the caret once the host publishes the insert. The numbers here
/// document the bug being prevented: the ghost render font is floored at 14pt, so measuring the
/// accepted chunk with it overshoots a 12pt host by more than the stability gate's 6pt drift
/// tolerance within one or two accepts, surfacing as a sideways nudge with no input in flight.
final class InsertedTextAdvanceTests: XCTestCase {
    func test_width_usesTheFieldsOwnFaceAndSize() throws {
        let helvetica12 = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
        let width = try XCTUnwrap(InsertedTextAdvance.width(of: " world", style: helvetica12))

        let expected = (" world" as NSString).size(withAttributes: [
            .font: try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        ]).width
        XCTAssertEqual(width, expected, accuracy: 0.01)
    }

    func test_width_atHostSizeIsSmallerThanTheGhostFloorMeasurement() throws {
        // The exact regression scenario: TextEdit renders Helvetica 12, the ghost renders the
        // same face at the 14pt legibility floor. The per-word delta must be visible to this
        // test the same way it was visible on screen.
        let host = try XCTUnwrap(
            InsertedTextAdvance.width(
                of: " world",
                style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
            )
        )
        let ghostFloor = try XCTUnwrap(
            InsertedTextAdvance.width(
                of: " world",
                style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 14, colorHex: nil)
            )
        )
        XCTAssertGreaterThan(ghostFloor - host, 3, "The 12pt vs 14pt mismatch is points per word, not noise")
    }

    func test_width_countsLeadingWhitespaceAsRealCaretTravel() throws {
        let style = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
        let bare = try XCTUnwrap(InsertedTextAdvance.width(of: "world", style: style))
        let spaced = try XCTUnwrap(InsertedTextAdvance.width(of: " world", style: style))
        XCTAssertGreaterThan(spaced, bare, "A boundary space moves the caret and must be measured")
    }

    func test_width_unknownFaceFallsBackToSystemAtTheHostsSize() throws {
        let style = ResolvedFieldStyle(fontName: "NoSuchFaceEver", fontPointSize: 12, colorHex: nil)
        let width = try XCTUnwrap(InsertedTextAdvance.width(of: " world", style: style))

        let expected = (" world" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12)
        ]).width
        XCTAssertEqual(width, expected, accuracy: 0.01)
    }

    @MainActor
    func test_predictedCaretRect_prefersTheHostFontOverTheSystemFallback() {
        let oldCaret = CGRect(x: 100, y: 20, width: 2, height: 18)
        let withHostFont = SuggestionCoordinator.predictedCaretRect(
            after: " world",
            oldCaretRect: oldCaret,
            caretQuality: .exact,
            observedCharWidth: nil,
            fieldStyle: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
        )
        let withSystemFallback = SuggestionCoordinator.predictedCaretRect(
            after: " world",
            oldCaretRect: oldCaret,
            caretQuality: .exact,
            observedCharWidth: nil
        )

        XCTAssertLessThan(
            withHostFont.origin.x,
            withSystemFallback.origin.x,
            "Helvetica 12 advances less than system 14; the prediction must track the host"
        )
        XCTAssertGreaterThan(withHostFont.origin.x, oldCaret.origin.x)
    }

    func test_width_prefersTheMeasuredRunCharWidthOverTheResolvedFont() throws {
        // Child-run derived hosts measure the average character width from the host's own rendered
        // run frames; that direct measurement outranks any font-based approximation.
        let style = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
        let measured = try XCTUnwrap(
            InsertedTextAdvance.width(of: " world", observedCharWidth: 7.5, style: style)
        )
        XCTAssertEqual(measured, 7.5 * 6, accuracy: 0.001)

        // Without the measurement the resolved font carries the estimate.
        let viaFont = try XCTUnwrap(
            InsertedTextAdvance.width(of: " world", observedCharWidth: nil, style: style)
        )
        XCTAssertEqual(
            viaFont,
            try XCTUnwrap(InsertedTextAdvance.width(of: " world", style: style)),
            accuracy: 0.001
        )

        XCTAssertNil(InsertedTextAdvance.width(of: " world", observedCharWidth: nil, style: nil))
        XCTAssertNil(InsertedTextAdvance.width(of: "", observedCharWidth: 7.5, style: style))
    }

    func test_width_refusesUnusableInputs() {
        XCTAssertNil(InsertedTextAdvance.width(of: "", style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)))
        XCTAssertNil(InsertedTextAdvance.width(of: " world", style: nil))
        XCTAssertNil(
            InsertedTextAdvance.width(
                of: " world",
                style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: nil, colorHex: nil)
            ),
            "A style without a point size cannot describe caret travel"
        )
        XCTAssertNil(
            InsertedTextAdvance.width(
                of: " world",
                style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 0, colorHex: nil)
            )
        )
    }
}
