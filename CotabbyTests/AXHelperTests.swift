import AppKit
import ApplicationServices
import XCTest
@testable import Cotabby

/// Exercises the AX bridging layer against the test host's own process.
///
/// App-hosted tests run inside the Cotabby app, so the suite can build a real window with a real
/// text view, then read it back through the same `AXUIElement` APIs production uses against other
/// apps. That validates the CF bridging, type guards, and traversal helpers against a live AX
/// implementation (AppKit's) rather than mocks. Environments where self-process AX is unavailable
/// (an untrusted headless CI runner) skip the live cases via `requireFieldElement`; the pure
/// helpers below run everywhere.
@MainActor
final class AXHelperTests: XCTestCase {
    private static var window: NSWindow?
    private static var textView: NSTextView?
    private static var fieldElement: AXUIElement?

    /// Builds the host window once for the whole suite; tearing it down per-test would re-pay AX
    /// tree registration and make later tests race the window server.
    private func requireFieldElement() throws -> AXUIElement {
        if let element = Self.fieldElement {
            return element
        }

        if Self.window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 420, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Cotabby AXHelper test host"
            let textView = NSTextView(frame: NSRect(x: 10, y: 10, width: 400, height: 180))
            textView.string = "The quick brown fox jumps over the lazy dog"
            textView.font = NSFont(name: "Helvetica", size: 13) ?? NSFont.systemFont(ofSize: 13)
            textView.textColor = .black
            textView.setAccessibilityIdentifier("cotabby-axhelper-test-field")
            window.contentView?.addSubview(textView)
            window.orderFrontRegardless()
            window.makeFirstResponder(textView)
            Self.window = window
            Self.textView = textView
        }

        // Locate the text area through the app's own AX tree, exactly as an assistive client
        // would. A miss here means this environment does not serve self-process AX.
        let appElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let element = Self.findTextArea(under: appElement, depth: 0) {
                Self.fieldElement = element
                return element
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        throw XCTSkip("Self-process AX is unavailable in this environment")
    }

    private static func findTextArea(under element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 8 else { return nil }
        if AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) == (kAXTextAreaRole as String),
           AXHelper.accessibilityIdentifier(of: element) == "cotabby-axhelper-test-field" {
            return element
        }
        for child in AXHelper.childElements(of: element) {
            if let found = findTextArea(under: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - Live AX reads against the host's own field

    func test_typedAttributeReaders_readTheRealFieldBack() throws {
        let element = try requireFieldElement()

        XCTAssertEqual(
            AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element),
            "The quick brown fox jumps over the lazy dog"
        )
        XCTAssertEqual(
            AXHelper.intValue(for: kAXNumberOfCharactersAttribute as CFString, on: element),
            43
        )
        XCTAssertNotNil(AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element))
        let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element)
        XCTAssertEqual(frame?.isEmpty, false)
        XCTAssertFalse(AXHelper.attributeNames(on: element).isEmpty)
        XCTAssertTrue(
            AXHelper.parameterizedAttributeNames(on: element)
                .contains(kAXBoundsForRangeParameterizedAttribute as String)
        )
    }

    func test_typedAttributeReaders_returnNilOnTypeMismatches() throws {
        let element = try requireFieldElement()

        // Each reader must reject a present-but-differently-typed value instead of bridging junk.
        XCTAssertNil(AXHelper.rangeValue(for: kAXRoleAttribute as CFString, on: element))
        XCTAssertNil(AXHelper.rectValue(for: kAXRoleAttribute as CFString, on: element))
        XCTAssertNil(AXHelper.intValue(for: kAXRoleAttribute as CFString, on: element))
        XCTAssertNil(AXHelper.boolValue(for: kAXRoleAttribute as CFString, on: element))
        XCTAssertNil(AXHelper.stringValue(for: "AXNoSuchAttribute" as CFString, on: element))
        XCTAssertNil(AXHelper.stringArrayValue(for: "AXDOMClassList" as CFString, on: element))
    }

    func test_parameterizedReaders_resolveRangesOnTheRealLayout() throws {
        let element = try requireFieldElement()

        XCTAssertEqual(
            AXHelper.parameterizedStringValue(
                for: kAXStringForRangeParameterizedAttribute as CFString,
                range: NSRange(location: 4, length: 5),
                on: element
            ),
            "quick"
        )

        let bounds = AXHelper.parameterizedRectValue(
            for: kAXBoundsForRangeParameterizedAttribute as CFString,
            range: NSRange(location: 0, length: 3),
            on: element
        )
        XCTAssertEqual(bounds?.isEmpty, false)

        let attributed = AXHelper.parameterizedAttributedStringValue(
            for: "AXAttributedStringForRange" as CFString,
            range: NSRange(location: 0, length: 1),
            on: element
        )
        XCTAssertEqual(attributed?.length, 1)
    }

    func test_resolveFieldStyle_readsFontAndColorFromTheHost() throws {
        let element = try requireFieldElement()

        let style = AXHelper.resolveFieldStyle(for: element, caretLocation: 5, textLength: 43)
        XCTAssertNotNil(style)
        XCTAssertEqual(style?.fontPointSize, 13)
        XCTAssertNotNil(style?.fontName)

        // Empty fields can have no style source at all; the helper must refuse, not crash.
        XCTAssertNil(AXHelper.resolveFieldStyle(for: element, caretLocation: 0, textLength: 0))
    }

    func test_treeTraversal_walksParentsChildrenAndIdentity() throws {
        let element = try requireFieldElement()

        let parent = AXHelper.parentElement(of: element)
        XCTAssertNotNil(parent)
        if let parent {
            XCTAssertFalse(AXHelper.childElements(of: parent).isEmpty)
        }

        let identity = AXHelper.elementIdentity(for: element)
        XCTAssertTrue(identity.hasPrefix("\(ProcessInfo.processInfo.processIdentifier)-"))
        XCTAssertEqual(
            AXHelper.elementIdentifier(for: element, bundleIdentifier: "com.example.test"),
            "com.example.test-\(identity)"
        )

        let owner = AXHelper.owningApplication(of: element)
        XCTAssertEqual(owner?.processIdentifier, ProcessInfo.processInfo.processIdentifier)
    }

    func test_nearestEditable_returnsTheEditableItselfAndClimbsFromLeaves() throws {
        let element = try requireFieldElement()

        // An already-editable element is returned as-is.
        let fromEditable = AXHelper.nearestEditable(from: element)
        XCTAssertEqual(AXHelper.elementIdentity(for: fromEditable), AXHelper.elementIdentity(for: element))

        // Climbing from a non-editable ancestor gives up after maxClimb and returns the original.
        if let parent = AXHelper.parentElement(of: element) {
            let fromParent = AXHelper.nearestEditable(from: parent, maxClimb: 0)
            XCTAssertEqual(
                AXHelper.elementIdentity(for: fromParent),
                AXHelper.elementIdentity(for: parent)
            )
        }
    }

    func test_markerAPIs_degradeToNilOnNativeElements() throws {
        let element = try requireFieldElement()

        // Native AppKit text views have no Chromium/WebKit text-marker surface; both helpers must
        // miss cleanly because production calls them on arbitrary focused elements.
        XCTAssertNil(AXHelper.textMarkerCaretRect(on: element))
        XCTAssertNil(AXHelper.synthesizeMarkerSelection(on: element, parameterizedAttributes: []))
        XCTAssertNil(
            AXHelper.synthesizeMarkerSelection(
                on: element,
                parameterizedAttributes: [
                    "AXStartTextMarkerForTextMarkerRange",
                    "AXEndTextMarkerForTextMarkerRange",
                    "AXTextMarkerRangeForUnorderedTextMarkers",
                    "AXStringForTextMarkerRange"
                ]
            )
        )
    }

    func test_webURL_missesCleanlyOnNonBrowserTrees() throws {
        let element = try requireFieldElement()
        XCTAssertNil(AXHelper.webURL(near: element, maxClimb: 2))
    }

    func test_focusQueries_resolveTheHostsOwnFocus() throws {
        let element = try requireFieldElement()
        Self.window?.makeFirstResponder(Self.textView)

        // The app-scoped focused-element query should land on our text area (or at least not
        // crash and return a typed element) while the field is first responder.
        let focused = AXHelper.focusedElement(
            forApplicationPID: ProcessInfo.processInfo.processIdentifier
        )
        if let focused {
            XCTAssertNotNil(AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focused))
        }
        _ = AXHelper.isFocused(element)
        // System-wide focus belongs to whatever app is active; the call just must not crash.
        _ = AXHelper.focusedElement()
    }

    func test_pasteMenuItem_findsCmdVInARealMenuBarWhenTrusted() throws {
        _ = try requireFieldElement()
        // Finder always runs and always has Edit > Paste bound to plain Cmd-V. Reading another
        // process's menu bar requires AX trust, so a nil result in an untrusted environment is
        // tolerated; a non-nil result must actually be a Cmd-V menu item carrier.
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Finder is not running")
        }
        let item = AXHelper.pasteMenuItem(forApplicationPID: finder.processIdentifier)
        if let item {
            let cmdChar = AXHelper.stringValue(for: kAXMenuItemCmdCharAttribute as CFString, on: item)
            XCTAssertEqual(cmdChar?.uppercased(), "V")
        }
    }

    // MARK: - Invalid-pid guards (no AX needed)

    func test_invalidPIDGuards_failFastWithoutTouchingAX() {
        XCTAssertNil(AXHelper.focusedElement(forApplicationPID: -1))
        XCTAssertNil(AXHelper.pasteMenuItem(forApplicationPID: 0))
        XCTAssertEqual(AXHelper.setManualAccessibility(true, forApplicationPID: -1), .failure)
    }

    // MARK: - Editability heuristics (pure)

    func test_editabilityHeuristics_scoreRolesAndExplicitFlags() {
        XCTAssertTrue(AXHelper.isKnownEditableRole(kAXTextFieldRole as String))
        XCTAssertTrue(AXHelper.isKnownEditableRole(kAXTextAreaRole as String))
        XCTAssertTrue(AXHelper.isKnownEditableRole("AXSearchField"))
        XCTAssertFalse(AXHelper.isKnownEditableRole(kAXStaticTextRole as String))

        XCTAssertTrue(AXHelper.isKnownReadOnlyRole(kAXStaticTextRole as String))
        XCTAssertTrue(AXHelper.isKnownReadOnlyRole(kAXButtonRole as String))
        XCTAssertFalse(AXHelper.isKnownReadOnlyRole(kAXTextFieldRole as String))

        XCTAssertEqual(AXHelper.editabilityHintScore(role: kAXTextFieldRole as String, explicitEditableFlag: true), 11)
        XCTAssertEqual(AXHelper.editabilityHintScore(role: kAXTextFieldRole as String, explicitEditableFlag: nil), 1)
        XCTAssertEqual(AXHelper.editabilityHintScore(role: "AXGroup", explicitEditableFlag: false), 0)

        XCTAssertTrue(AXHelper.hasStrongEditabilitySignal(role: "AXGroup", explicitEditableFlag: true))
        XCTAssertTrue(AXHelper.hasStrongEditabilitySignal(role: kAXComboBoxRole as String, explicitEditableFlag: nil))
        XCTAssertFalse(AXHelper.hasStrongEditabilitySignal(role: "AXGroup", explicitEditableFlag: nil))
    }

    // MARK: - Coordinate conversion (pure over live screen geometry)

    func test_rectHasFiniteComponents_rejectsNaNAndInfinity() {
        XCTAssertTrue(AXHelper.rectHasFiniteComponents(CGRect(x: 1, y: 2, width: 3, height: 4)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: CGFloat.nan, y: 2, width: 3, height: 4)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: 1, y: CGFloat.infinity, width: 3, height: 4)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: 1, y: 2, width: -CGFloat.infinity, height: 4)))
        XCTAssertFalse(AXHelper.rectHasFiniteComponents(CGRect(x: 1, y: 2, width: 3, height: CGFloat.nan)))
    }

    func test_cocoaRect_zeroAndNonFiniteRectsNeverReachGeometryMath() {
        XCTAssertEqual(AXHelper.cocoaRect(fromAccessibilityRect: .zero), .zero)
        XCTAssertEqual(
            AXHelper.cocoaRect(fromAccessibilityRect: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)),
            .zero
        )
    }

    func test_cocoaRect_preservesSizeAndFlipsWithinThePrimaryDisplay() throws {
        guard let primary = NSScreen.screens.first else {
            throw XCTSkip("No display attached")
        }
        // A rect 100pt below the AX top-left origin must come back 100pt below the Cocoa top.
        let axRect = CGRect(x: 50, y: 100, width: 200, height: 20)
        let converted = AXHelper.cocoaRect(fromAccessibilityRect: axRect)
        XCTAssertEqual(converted.width, 200)
        XCTAssertEqual(converted.height, 20)
        XCTAssertEqual(converted.minX, 50)
        XCTAssertEqual(converted.maxY, primary.frame.maxY - 100, accuracy: 0.5)
    }

    func test_validatedCocoaTextRect_anchorsDecideBetweenCandidates() throws {
        guard let primary = NSScreen.screens.first else {
            throw XCTSkip("No display attached")
        }

        XCTAssertEqual(
            AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1),
                anchorFrame: nil
            ),
            .zero
        )
        XCTAssertEqual(
            AXHelper.validatedCocoaTextRect(fromAccessibilityRect: .zero, anchorFrame: nil),
            .zero
        )

        // No anchor: the plain Y-flip candidate wins.
        let axRect = CGRect(x: 50, y: 100, width: 10, height: 20)
        let unanchored = AXHelper.validatedCocoaTextRect(fromAccessibilityRect: axRect, anchorFrame: nil)
        XCTAssertEqual(unanchored.maxY, primary.frame.maxY - 100, accuracy: 0.5)

        // An anchor surrounding the flipped candidate keeps it.
        let goodAnchor = unanchored.insetBy(dx: -40, dy: -40)
        XCTAssertEqual(
            AXHelper.validatedCocoaTextRect(fromAccessibilityRect: axRect, anchorFrame: goodAnchor),
            unanchored
        )

        // An anchor nowhere near either candidate falls back to the flipped rect rather than
        // inventing geometry.
        let farAnchor = CGRect(x: 5_000, y: 5_000, width: 10, height: 10)
        XCTAssertEqual(
            AXHelper.validatedCocoaTextRect(fromAccessibilityRect: axRect, anchorFrame: farAnchor),
            unanchored
        )
    }

    // MARK: - System-wide element

    func test_systemWideElement_isCreatedWithTheShortMessagingTimeout() {
        // The timeout itself is not readable back, but creation must succeed and be callable.
        let element = AXHelper.systemWideElement()
        XCTAssertEqual(CFGetTypeID(element), AXUIElementGetTypeID())
    }
}
