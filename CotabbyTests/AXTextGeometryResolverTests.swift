import AppKit
import ApplicationServices
import XCTest
@testable import Cotabby

/// Tests for `AXTextGeometryResolver` caret resolution branch ordering.
///
/// These tests use a real `NSTextField` hosted in the test process to exercise the AX geometry
/// pipeline end-to-end. Native AppKit text fields reliably support `AXBoundsForRange`, so they
/// validate that the optimistic BoundsForRange path produces `.exact` quality without requiring
/// the element to advertise the attribute in `parameterizedAttributeNames`.
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

    func test_resolveCaretRect_returnsExactQuality_forNativeTextField() {
        let (field, window) = makeTextField(text: "Hello world")
        defer { window.orderOut(nil) }

        // Place caret at position 5.
        field.currentEditor()?.selectedRange = NSRange(location: 5, length: 0)

        // Get the AXUIElement for the focused field editor.
        guard let focusedElement = AXHelper.focusedElement() else {
            // AX permissions may not be available in CI — skip rather than fail.
            XCTSkip("Accessibility permissions not available in this environment")
            return
        }

        let result = resolver.resolveCaretRect(
            for: focusedElement,
            selection: NSRange(location: 5, length: 0),
            supportsFrame: true,
            cocoaAnchorFrame: nil
        )

        XCTAssertNotNil(result, "Should resolve caret rect for native text field")
        if let result {
            XCTAssertEqual(result.quality, .exact, "Native NSTextField should yield exact quality via BoundsForRange")
            XCTAssertFalse(result.rect.isEmpty, "Caret rect should not be empty")
            XCTAssertGreaterThan(result.rect.height, 0, "Caret rect should have positive height")
        }
    }

    // MARK: - Fallback chain: non-nil result even at position 0

    func test_resolveCaretRect_returnsResult_atCaretPositionZero() {
        let (field, window) = makeTextField(text: "Test")
        defer { window.orderOut(nil) }

        field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)

        guard let focusedElement = AXHelper.focusedElement() else {
            XCTSkip("Accessibility permissions not available in this environment")
            return
        }

        let result = resolver.resolveCaretRect(
            for: focusedElement,
            selection: NSRange(location: 0, length: 0),
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
    func test_resolveCaretRect_returnsResult_withTextValueOverload() {
        let (field, window) = makeTextField(text: "Fallback test")
        defer { window.orderOut(nil) }

        field.currentEditor()?.selectedRange = NSRange(location: 3, length: 0)

        guard let focusedElement = AXHelper.focusedElement() else {
            XCTSkip("Accessibility permissions not available in this environment")
            return
        }

        let result = resolver.resolveCaretRect(
            for: focusedElement,
            selection: NSRange(location: 3, length: 0),
            supportsFrame: true,
            cocoaAnchorFrame: nil,
            textValue: "Fallback test"
        )

        XCTAssertNotNil(result)
    }
}
