import AppKit
import ApplicationServices
import XCTest
@testable import Cotabby

/// End-to-end resolver coverage against a real AX implementation: the suite builds windows with
/// real AppKit text fields inside the test host, then runs `FocusSnapshotResolver.resolveSnapshot`
/// on their live `AXUIElement`s. This validates candidate search, capability gating, text-window
/// slicing, caret-geometry resolution, and snapshot assembly against AppKit's actual AX surface
/// instead of mocks. Skips (rather than fails) where self-process AX is unavailable, e.g. an
/// untrusted headless CI runner.
@MainActor
final class FocusSnapshotResolverLiveTests: XCTestCase {
    private static var window: NSWindow?
    private static var textView: NSTextView?
    private static var secureField: NSSecureTextField?

    private static let bodyText = "Pack my box with five dozen liquor jugs"

    private func requireElements() throws -> (text: AXUIElement, secure: AXUIElement) {
        if let text = Self.textElement, let secure = Self.secureElement {
            return (text, secure)
        }

        if Self.window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 160, y: 160, width: 460, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Cotabby resolver test host"
            let textView = NSTextView(frame: NSRect(x: 10, y: 60, width: 440, height: 170))
            textView.string = Self.bodyText
            textView.font = NSFont(name: "Helvetica", size: 13) ?? NSFont.systemFont(ofSize: 13)
            textView.setAccessibilityIdentifier("cotabby-resolver-test-field")
            let secureField = NSSecureTextField(frame: NSRect(x: 10, y: 16, width: 200, height: 24))
            secureField.stringValue = "hunter2"
            window.contentView?.addSubview(textView)
            window.contentView?.addSubview(secureField)
            window.orderFrontRegardless()
            window.makeFirstResponder(textView)
            Self.window = window
            Self.textView = textView
            Self.secureField = secureField
        }

        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = Self.textElement, let secure = Self.secureElement {
                return (text, secure)
            }
            _ = Self.cacheElements(under: appElement, depth: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        throw XCTSkip("Self-process AX is unavailable in this environment")
    }

    private static var textElement: AXUIElement?
    private static var secureElement: AXUIElement?

    private static func cacheElements(under element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 8 else { return false }
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
        if role == (kAXTextAreaRole as String),
           AXHelper.accessibilityIdentifier(of: element) == "cotabby-resolver-test-field" {
            textElement = element
        }
        if role == (kAXTextFieldRole as String),
           AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element) == "AXSecureTextField" {
            secureElement = element
        }
        if textElement != nil, secureElement != nil {
            return true
        }
        for child in AXHelper.childElements(of: element) where cacheElements(under: child, depth: depth + 1) {
            return true
        }
        return false
    }

    private var resolver: FocusSnapshotResolver {
        FocusSnapshotResolver()
    }

    func test_resolveSnapshot_supportedFieldCarriesTextSelectionAndGeometry() throws {
        let elements = try requireElements()
        Self.textView?.setSelectedRange(NSRange(location: 8, length: 0))

        let snapshot = resolver.resolveSnapshot(
            focusedElement: elements.text,
            application: NSRunningApplication.current,
            focusChangeSequence: 42
        )

        guard case .supported = snapshot.capability else {
            return XCTFail("Expected supported, got \(snapshot.capability.summary)")
        }
        guard let context = snapshot.context else {
            return XCTFail("Supported snapshot must carry a context")
        }
        XCTAssertEqual(context.precedingText, "Pack my ")
        XCTAssertEqual(context.trailingText, "box with five dozen liquor jugs")
        XCTAssertEqual(context.selection.length, 0)
        XCTAssertEqual(context.focusChangeSequence, 42)
        XCTAssertFalse(context.isSecure)
        XCTAssertFalse(context.caretRect.isEmpty, "A real caret rect must resolve from live AX")
        XCTAssertNotEqual(context.caretQuality, .estimated, "AppKit serves real text geometry")
        XCTAssertEqual(context.inputFrameRect?.isEmpty, false)
        XCTAssertEqual(context.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(context.resolvedFieldStyle?.fontPointSize, 13)
    }

    func test_resolveSnapshot_selectionRangeBlocksAssistance() throws {
        let elements = try requireElements()
        Self.textView?.setSelectedRange(NSRange(location: 0, length: 4))
        defer { Self.textView?.setSelectedRange(NSRange(location: 8, length: 0)) }

        let snapshot = resolver.resolveSnapshot(
            focusedElement: elements.text,
            application: NSRunningApplication.current
        )

        guard case let .blocked(reason) = snapshot.capability else {
            return XCTFail("Expected blocked, got \(snapshot.capability.summary)")
        }
        XCTAssertTrue(reason.contains("selected"))
        XCTAssertNotNil(snapshot.context, "Blocked snapshots still carry context for diagnostics")
    }

    func test_resolveSnapshot_secureFieldIsBlockedNotUnsupported() throws {
        let elements = try requireElements()

        let snapshot = resolver.resolveSnapshot(
            focusedElement: elements.secure,
            application: NSRunningApplication.current
        )

        guard case let .blocked(reason) = snapshot.capability else {
            return XCTFail("Expected blocked, got \(snapshot.capability.summary)")
        }
        XCTAssertTrue(reason.contains("Secure"), "Got: \(reason)")
        XCTAssertEqual(snapshot.context?.isSecure, true)
    }

    func test_resolveSnapshot_nonEditableElementIsUnsupportedWithInspection() throws {
        _ = try requireElements()

        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowValue) == .success,
              let windows = windowValue as? [AnyObject],
              let first = windows.first,
              CFGetTypeID(first) == AXUIElementGetTypeID() else {
            throw XCTSkip("Window AX element unavailable")
        }
        let windowElement = unsafeBitCast(first, to: AXUIElement.self)

        let snapshot = resolver.resolveSnapshot(
            focusedElement: windowElement,
            application: NSRunningApplication.current
        )

        // Whichever editable the candidate walk happens to find (the window owns two), the result
        // must be deterministic in shape: either a supported editable resolved from descendants,
        // or a structured unsupported reason; never a crash or an empty-context "supported".
        switch snapshot.capability {
        case .supported:
            XCTAssertNotNil(snapshot.context)
        case .blocked, .unsupported:
            XCTAssertNotNil(snapshot.inspection)
        }
    }

    func test_resolveSnapshot_caretWindowBoundsLargeDocuments() throws {
        let elements = try requireElements()
        let hugePrefix = String(repeating: "a", count: 6_000)
        Self.textView?.string = hugePrefix + "tail"
        Self.textView?.setSelectedRange(NSRange(location: 6_000, length: 0))
        defer {
            Self.textView?.string = Self.bodyText
            Self.textView?.setSelectedRange(NSRange(location: 8, length: 0))
        }

        let snapshot = resolver.resolveSnapshot(
            focusedElement: elements.text,
            application: NSRunningApplication.current
        )

        guard let context = snapshot.context else {
            return XCTFail("Expected a context for the large document")
        }
        XCTAssertLessThanOrEqual(
            context.precedingText.utf16.count,
            FocusSnapshotResolver.focusedTextContextWindowUTF16,
            "The caret window must cap what flows into equality checks and signatures"
        )
        XCTAssertTrue(context.precedingText.allSatisfy { $0 == "a" })
        XCTAssertEqual(context.trailingText, "tail")
    }
}
