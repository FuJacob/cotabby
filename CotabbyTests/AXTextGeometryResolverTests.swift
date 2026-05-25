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
}
