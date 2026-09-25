import AppKit
import ApplicationServices
import XCTest
@testable import Cotabby

/// Tests for `AXTextGeometryResolver` caret resolution branch ordering.
///
/// These tests use a real `NSTextField` hosted in the test process to exercise the AX geometry
/// pipeline end-to-end. Native AppKit text fields reliably support `AXBoundsForRange` and
/// advertise it via `parameterizedAttributeNames`, so the resolver's Branch 1/2 are reachable
/// when callers pass `supportsBoundsForRange: true`.
@MainActor
final class AXTextGeometryResolverTests: XCTestCase {
    private let resolver = AXTextGeometryResolver()

    /// A real AppKit text field gives us a genuine AXUIElement that responds to BoundsForRange.
    private func makeTextField(text: String = "Hello world") -> (NSTextField, NSWindow) {
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)

        // Host in an off-screen window so AX queries work.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)

        return (field, window)
    }

    // MARK: - Branch 1: Optimistic BoundsForRange

    func test_resolveCaretRect_returnsRealGeometry_forNativeTextField() throws {
        let (field, window) = makeTextField(text: "Hello world")
        defer { window.orderOut(nil) }

        // Place caret at position 5.
        field.currentEditor()?.selectedRange = NSRange(location: 5, length: 0)

        // Get the AXUIElement for the focused field editor.
        guard let focusedElement = AXHelper.focusedElement() else {
            // AX permissions may not be available in CI — skip rather than fail.
            throw XCTSkip("Accessibility permissions not available in this environment")
        }

        let resolved = resolver.resolveCaretRect(
            for: focusedElement,
            selection: NSRange(location: 5, length: 0),
            supportsBoundsForRange: true,
            supportsFrame: true,
            cocoaAnchorFrame: nil
        )

        // Optimistic BoundsForRange should yield real geometry without the element advertising the
        // attribute. We accept `.exact` (zero-length BoundsForRange, Branch 1) or `.derived`
        // (char-before shift, Branch 2): a headless/off-screen field often returns an empty
        // zero-length rect and legitimately falls through to Branch 2. What matters is that we did
        // NOT fall all the way to an `.estimated` AXFrame guess.
        let result = try XCTUnwrap(resolved, "Should resolve caret rect for native text field")
        XCTAssertTrue(
            result.quality == .exact || result.quality == .derived,
            "Native NSTextField should yield BoundsForRange geometry, got \(result.quality.label)"
        )
        XCTAssertFalse(result.rect.isEmpty, "Caret rect should not be empty")
        XCTAssertGreaterThan(result.rect.height, 0, "Caret rect should have positive height")
    }

    // MARK: - Fallback chain: non-nil result even at position 0

    func test_resolveCaretRect_returnsResult_atCaretPositionZero() throws {
        let (field, window) = makeTextField(text: "Test")
        defer { window.orderOut(nil) }

        field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)

        guard let focusedElement = AXHelper.focusedElement() else {
            throw XCTSkip("Accessibility permissions not available in this environment")
        }

        let result = resolver.resolveCaretRect(
            for: focusedElement,
            selection: NSRange(location: 0, length: 0),
            supportsBoundsForRange: true,
            supportsFrame: true,
            cocoaAnchorFrame: nil
        )

        XCTAssertNotNil(result, "Should produce a caret rect even at position 0")
    }

    // MARK: - Signature: textValue overload still resolves

    /// Exercises the `textValue` overload of `resolveCaretRect` (the parameter the AXFrame
    /// fallback consumes) and confirms the optimistic-BoundsForRange refactor still returns a
    /// usable rect. This does NOT cover the `.estimated` AXFrame branch: a live native field
    /// reliably supports BoundsForRange and so hits Branch 1. Forcing the fallback would require
    /// a stub element where BoundsForRange returns nil, which this test does not construct.
    func test_resolveCaretRect_returnsResult_withTextValueOverload() throws {
        let (field, window) = makeTextField(text: "Fallback test")
        defer { window.orderOut(nil) }

        field.currentEditor()?.selectedRange = NSRange(location: 3, length: 0)

        guard let focusedElement = AXHelper.focusedElement() else {
            throw XCTSkip("Accessibility permissions not available in this environment")
        }

        let result = resolver.resolveCaretRect(
            for: focusedElement,
            selection: NSRange(location: 3, length: 0),
            supportsBoundsForRange: true,
            supportsFrame: true,
            cocoaAnchorFrame: nil,
            textValue: "Fallback test"
        )

        XCTAssertNotNil(result)
    }

    // MARK: - AXFrame-only estimated caret line

    func test_estimatedCaretRect_centersSingleLineInsideFieldChrome() {
        let field = CGRect(x: 100, y: 200, width: 500, height: 54)

        let caret = resolver.estimatedCaretRect(in: field, caretX: 420, text: "hello world")

        XCTAssertEqual(caret.midY, field.midY, accuracy: 0.001)
        XCTAssertLessThan(caret.height, field.height)
        XCTAssertEqual(caret.minX, 420)
        XCTAssertEqual(caret.width, 2)
    }

    func test_estimatedCaretRect_bottomAlignsExplicitMultilineValue() {
        let field = CGRect(x: 100, y: 200, width: 500, height: 120)

        let caret = resolver.estimatedCaretRect(in: field, caretX: 420, text: "first\nsecond")

        XCTAssertEqual(caret.minY, field.minY, accuracy: 0.001)
        XCTAssertLessThan(caret.height, field.height)
    }

    // MARK: - rectIsNearAnchor (the optimistic-BoundsForRange safety check)

    /// The anchor-rejection boundary is the whole point of dropping the `supportsBoundsForRange`
    /// gate, so test it directly rather than relying on a live element returning a controllable
    /// rect. The accept window is the anchor expanded by the 80pt halo.
    func test_rectIsNearAnchor_acceptsRectInsideHalo() {
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 24)
        // Midpoint (160, 112) is inside the anchor itself.
        XCTAssertTrue(resolver.rectIsNearAnchor(CGRect(x: 150, y: 105, width: 20, height: 14), anchor: anchor))
        // Just outside the anchor but within the 80pt halo (midpoint x = 360, anchor maxX = 300).
        XCTAssertTrue(resolver.rectIsNearAnchor(CGRect(x: 355, y: 105, width: 10, height: 14), anchor: anchor))
    }

    func test_rectIsNearAnchor_rejectsRectOutsideHalo() {
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 24)
        // Midpoint far away (a foreign element's rect) — outside anchor + 80pt halo.
        XCTAssertFalse(resolver.rectIsNearAnchor(CGRect(x: 900, y: 900, width: 20, height: 14), anchor: anchor))
    }

    /// No anchor means we cannot validate, so the resolver preserves legacy behavior and accepts.
    func test_rectIsNearAnchor_acceptsWhenAnchorMissingOrEmpty() {
        let rect = CGRect(x: 900, y: 900, width: 20, height: 14)
        XCTAssertTrue(resolver.rectIsNearAnchor(rect, anchor: nil))
        XCTAssertTrue(resolver.rectIsNearAnchor(rect, anchor: .zero))
    }

    // MARK: - Non-finite AX rect rejection (crash guard)

    func test_rectHasFiniteComponents_rejectsNaNAndInfinity() {
        XCTAssertTrue(AXHelper.rectHasFiniteComponents(CGRect(x: 1, y: 2, width: 3, height: 4)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: 0, y: CGFloat.nan, width: 10, height: CGFloat.nan)))
    }

    func test_validatedCocoaTextRect_collapsesNonFiniteRectToZero() {
        // A NaN/Inf AX rect must collapse to .zero, never propagate toward NSWindow.setFrame (a crash).
        let nan = CGRect(x: CGFloat.nan, y: 10, width: 20, height: 14)
        XCTAssertEqual(AXHelper.validatedCocoaTextRect(fromAccessibilityRect: nan, anchorFrame: nil), .zero)
        XCTAssertEqual(AXHelper.cocoaRect(fromAccessibilityRect: nan), .zero)
    }

    // MARK: - Line-content edges

    /// A scripted host for the three line queries that records every call, so the tests can assert
    /// on what was *asked* as well as what came back. `lines` maps a caret offset's line number to
    /// that line's character range and its box in Accessibility (top-left) coordinates.
    private final class ScriptedLineHost {
        var calls: [String] = []
        let lineForOffset: (Int) -> Int?
        let lines: [Int: (range: NSRange, box: CGRect)]

        init(lineForOffset: @escaping (Int) -> Int?, lines: [Int: (range: NSRange, box: CGRect)]) {
            self.lineForOffset = lineForOffset
            self.lines = lines
        }

        var queries: AXTextGeometryResolver.LineGeometryQueries {
            AXTextGeometryResolver.LineGeometryQueries(
                lineForIndex: { [unowned self] offset in
                    self.calls.append("lineForIndex")
                    return self.lineForOffset(offset)
                },
                rangeForLine: { [unowned self] line in
                    self.calls.append("rangeForLine")
                    return self.lines[line]?.range
                },
                boundsForRange: { [unowned self] range in
                    self.calls.append("boundsForRange")
                    return self.lines.values.first { $0.range == range }?.box
                }
            )
        }
    }

    /// A paragraph starting at offset 100 whose first visual line (offsets 100-139) is indented 72pt
    /// past the margin its continuation line (offsets 140-179) wraps to.
    private func indentedParagraphHost() -> ScriptedLineHost {
        ScriptedLineHost(
            lineForOffset: { $0 < 140 ? 3 : 4 },
            lines: [
                3: (NSRange(location: 100, length: 40), CGRect(x: 360, y: 300, width: 500, height: 30)),
                4: (NSRange(location: 140, length: 40), CGRect(x: 288, y: 330, width: 572, height: 30))
            ]
        )
    }

    private func request(
        caretLocation: Int,
        paragraphStart: Int? = 100,
        anchorFrame: CGRect? = nil,
        supportsLineGeometry: Bool = true
    ) -> AXTextGeometryResolver.LineEdgeRequest {
        AXTextGeometryResolver.LineEdgeRequest(
            caretLocation: caretLocation,
            paragraphStart: paragraphStart,
            anchorFrame: anchorFrame,
            supportsLineGeometry: supportsLineGeometry
        )
    }

    private struct NotMeasured: Error, CustomStringConvertible {
        let outcome: LineContentEdgesOutcome
        var description: String { "expected a measurement, got \(outcome)" }
    }

    /// Unwraps a `.measured` outcome; any other outcome throws, which fails the test.
    private func measurement(_ outcome: LineContentEdgesOutcome) throws -> LineContentEdgesMeasurement {
        guard case .measured(let measurement) = outcome else {
            throw NotMeasured(outcome: outcome)
        }
        return measurement
    }

    /// The lookup issues synchronous cross-process AX calls. Against a host that does not implement
    /// them, each one blocks for the full messaging timeout, and doing that from the focus path is
    /// what froze typing in the `AXBoundsForRange` incident. The gate must stop before any call.
    func test_resolveLineContentEdges_unsupportedHostIsNeverQueried() {
        let host = indentedParagraphHost()

        let result = resolver.resolveLineContentEdges(
            using: host.queries,
            request: request(caretLocation: 150, supportsLineGeometry: false)
        )

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(host.calls, [], "the capability gate must short-circuit before any AX call")
    }

    /// A negative caret offset is rejected on its own, independently of the capability gate, so a
    /// bad selection cannot reach the parameterized calls either.
    func test_resolveLineContentEdges_negativeCaretIsNeverQueried() {
        let host = indentedParagraphHost()

        XCTAssertEqual(
            resolver.resolveLineContentEdges(using: host.queries, request: request(caretLocation: -1)),
            .unavailable
        )
        XCTAssertEqual(host.calls, [])
    }

    func test_resolveLineContentEdges_continuationLineIsTheParagraphMargin() throws {
        let host = indentedParagraphHost()

        let result = try measurement(
            resolver.resolveLineContentEdges(using: host.queries, request: request(caretLocation: 150))
        )

        XCTAssertFalse(result.isParagraphFirstLine)
        XCTAssertEqual(result.edges.leftX, 288, accuracy: 0.001)
        XCTAssertEqual(result.caretLocation, 150)
        XCTAssertEqual(host.calls, ["lineForIndex", "rangeForLine", "boundsForRange"])
    }

    /// A first line's left edge includes any first-line indent, so it is flagged as provisional for
    /// the caller to replace once the caret reaches a continuation line.
    func test_resolveLineContentEdges_firstLineIsFlaggedProvisional() throws {
        let host = indentedParagraphHost()

        let result = try measurement(
            resolver.resolveLineContentEdges(using: host.queries, request: request(caretLocation: 120))
        )

        XCTAssertTrue(result.isParagraphFirstLine)
        XCTAssertEqual(result.edges.leftX, 360, accuracy: 0.001)
    }

    /// With the paragraph start out of the text window the paragraph began over a window of text
    /// back, and no visual line is that long, so the caret's line is a continuation line.
    func test_resolveLineContentEdges_unknownParagraphStartMeansContinuationLine() throws {
        let host = indentedParagraphHost()

        let result = try measurement(
            resolver.resolveLineContentEdges(
                using: host.queries,
                request: request(caretLocation: 120, paragraphStart: nil)
            )
        )

        XCTAssertFalse(result.isParagraphFirstLine)
    }

    /// One line's top is not the text block's top, and the caret layout estimator reads `topY` as
    /// the block's top inset — so a line-query margin must carry no `topY` and no run-measured trust.
    func test_resolveLineContentEdges_publishesALeftMarginOnly() throws {
        let host = indentedParagraphHost()

        let result = try measurement(
            resolver.resolveLineContentEdges(using: host.queries, request: request(caretLocation: 150))
        )

        XCTAssertNil(result.edges.topY)
        XCTAssertFalse(result.edges.isRunMeasured)
    }

    /// Right after Return the caret's line is empty; there is no box to measure, so the lookup stops
    /// before asking for bounds — and says so, because unlike other failures typing fixes it.
    func test_resolveLineContentEdges_emptyLineIsReportedWithoutAskingForBounds() {
        let host = ScriptedLineHost(
            lineForOffset: { _ in 5 },
            lines: [5: (NSRange(location: 0, length: 0), CGRect(x: 288, y: 300, width: 0, height: 30))]
        )

        XCTAssertEqual(
            resolver.resolveLineContentEdges(using: host.queries, request: request(caretLocation: 17)),
            .emptyLine(caretLocation: 17)
        )
        XCTAssertEqual(host.calls, ["lineForIndex", "rangeForLine"])
    }

    /// A line holding only a paragraph break can come back with a zero-width box: just as empty.
    func test_resolveLineContentEdges_zeroWidthLineBoxIsAnEmptyLine() {
        let host = ScriptedLineHost(
            lineForOffset: { _ in 5 },
            lines: [5: (NSRange(location: 17, length: 1), CGRect(x: 288, y: 300, width: 0, height: 30))]
        )

        XCTAssertEqual(
            resolver.resolveLineContentEdges(using: host.queries, request: request(caretLocation: 17)),
            .emptyLine(caretLocation: 17)
        )
    }

    func test_resolveLineContentEdges_lineOutsideTheFieldIsRejected() {
        let host = indentedParagraphHost()
        // A field far from the scripted line boxes: a line rect that escapes the field is a
        // mis-reported range, not a margin.
        let field = AXHelper.cocoaRect(fromAccessibilityRect: CGRect(x: 2000, y: 2000, width: 300, height: 100))

        XCTAssertEqual(
            resolver.resolveLineContentEdges(
                using: host.queries,
                request: request(caretLocation: 150, anchorFrame: field)
            ),
            .unavailable
        )
    }
}
