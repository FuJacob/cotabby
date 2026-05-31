import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Wraps macOS Accessibility APIs behind Swift-friendly helpers for typed values, tree traversal,
/// element identity, and coordinate normalization.
///
/// This file is intentionally the "ugly edge" of the app. Accessibility APIs are Core Foundation
/// APIs, so they use loosely typed `CFTypeRef` values, C functions, and platform quirks that we do
/// not want spread throughout the rest of the codebase.
enum AXHelper {
    private static let knownEditableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXSearchField",
        kAXComboBoxRole as String
    ]

    private static let knownReadOnlyRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXImageRole as String,
        kAXButtonRole as String,
        "AXLink",
        kAXMenuItemRole as String
    ]

    // MARK: - Messaging Timeout

    /// Per-poll AX messaging timeout, in seconds.
    ///
    /// Every `AXUIElement` call is a synchronous cross-process request that blocks the calling
    /// (main) thread until the target app replies or this timeout fires. The OS default is ~6s,
    /// which on our 80ms focus poll means a single slow or wedged app can beachball typing. A
    /// short timeout makes such an app degrade to "no suggestion this tick" instead of stalling
    /// the UI; callers already treat a nil/`.cannotComplete` result as a normal miss.
    private static let pollMessagingTimeout: Float = 0.05

    /// Returns a system-wide AX element with the poll messaging timeout applied. Setting the
    /// timeout on the system-wide object establishes the default for every element that does not
    /// set its own (per `AXUIElementSetMessagingTimeout` semantics), so this is the single choke
    /// point for both focus and hit-test queries.
    static func systemWideElement() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, pollMessagingTimeout)
        return element
    }

    // MARK: - Attribute Reading

    /// Returns the AX attribute names exposed by an element.
    /// These lists let higher-level code feature-detect capabilities instead of assuming that
    /// every app exposes the same Accessibility surface.
    static func attributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    /// Returns the parameterized AX attribute names exposed by an element.
    /// Parameterized attributes are queries such as "bounds for this text range".
    static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }

        return names as? [String] ?? []
    }

    /// Reads a string AX attribute when the underlying value is present and type-compatible.
    static func stringValue(for attribute: CFString, on element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(attribute, on: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    static func boolValue(for attribute: CFString, on element: AXUIElement) -> Bool? {
        guard let number = copyAttributeValue(attribute, on: element) as? NSNumber else {
            return nil
        }

        return number.boolValue
    }

    static func intValue(for attribute: CFString, on element: AXUIElement) -> Int? {
        guard let number = copyAttributeValue(attribute, on: element) as? NSNumber else {
            return nil
        }

        return number.intValue
    }

    /// Converts loosely typed Accessibility values into `AXValue` only after verifying the Core
    /// Foundation type id. This keeps the unsafe CF boundary in one place and avoids force casts in
    /// the higher-level helpers below.
    private static func axValue(from value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXValue.self)
    }

    /// Reads an `AXValue`-backed range attribute such as the current selection.
    static func rangeValue(for attribute: CFString, on element: AXUIElement) -> NSRange? {
        guard let axValue = axValue(from: copyAttributeValue(attribute, on: element)) else { return nil }
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    /// Reads an `AXValue`-backed rectangle attribute such as `AXFrame`.
    static func rectValue(for attribute: CFString, on element: AXUIElement) -> CGRect? {
        guard let axValue = axValue(from: copyAttributeValue(attribute, on: element)) else { return nil }
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Reads a parameterized rectangle attribute such as `AXBoundsForRange`.
    static func parameterizedRectValue(
        for attribute: CFString,
        range: NSRange,
        on element: AXUIElement
    ) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success, let axValue = axValue(from: value) else { return nil }
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    /// Reads a parameterized string range without asking the host app to serialize the whole field.
    ///
    /// Large browser editors can expose many thousands of characters through `AXValue`. Pulling the
    /// entire value on every focus refresh is expensive because each read is synchronous IPC into
    /// the host process. `AXStringForRange` lets callers request only the caret-adjacent window that
    /// autocomplete actually needs, while preserving the normal full-value fallback for apps that
    /// do not implement the parameterized string API.
    static func parameterizedStringValue(
        for attribute: CFString,
        range: NSRange,
        on element: AXUIElement
    ) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success, let value else { return nil }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    /// Some applications (like Chromium and WebKit browsers) do not properly support `AXBoundsForRange`
    /// using `NSRange`. Instead, they use a private, undocumented Accessibility object called `AXTextMarker`.
    ///
    /// To get the caret rect from these apps, we must:
    /// 1. Ask for `AXSelectedTextMarkerRange` (which returns an opaque `AXTextMarkerRange`).
    /// 2. Pass that marker range back to the element using `AXBoundsForTextMarkerRange`.
    ///
    /// This bypasses the need to translate `NSRange` manually and forces the browser to resolve
    /// the physical layout of its own internal selection object.
    static func textMarkerCaretRect(on element: AXUIElement) -> CGRect? {
        // 1. Get the opaque AXTextMarkerRange that represents the current selection/caret.
        let selectedMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
        var markerRangeValue: CFTypeRef?

        var result = AXUIElementCopyAttributeValue(element, selectedMarkerRangeAttribute, &markerRangeValue)
        guard result == .success, let markerRange = markerRangeValue else {
            return nil
        }

        // 2. Ask the element to compute the bounding box for that exact text marker range.
        let boundsForMarkerRangeAttribute = "AXBoundsForTextMarkerRange" as CFString
        var boundsValue: CFTypeRef?

        result = AXUIElementCopyParameterizedAttributeValue(element, boundsForMarkerRangeAttribute, markerRange, &boundsValue)
        guard result == .success, let axBounds = axValue(from: boundsValue) else { return nil }
        guard AXValueGetType(axBounds) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else {
            return nil
        }

        return rect
    }

    // MARK: - Text Markers (Chromium / WebKit contenteditable selection)

    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
    private static let startTextMarkerAttribute = "AXStartTextMarker" as CFString
    private static let endTextMarkerAttribute = "AXEndTextMarker" as CFString
    private static let startMarkerForRangeAttribute = "AXStartTextMarkerForTextMarkerRange" as CFString
    private static let endMarkerForRangeAttribute = "AXEndTextMarkerForTextMarkerRange" as CFString
    private static let markerRangeForMarkersAttribute = "AXTextMarkerRangeForUnorderedTextMarkers" as CFString
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString

    /// Synthesizes an `NSRange` selection plus caret-windowed text for a Chromium/WebKit
    /// `contenteditable` that exposes selection only through the opaque text-marker API and not
    /// through `kAXSelectedTextRangeAttribute`.
    ///
    /// Without this, such fields (Gmail body, Slack/Notion/Discord web, ClickUp chat) fail the
    /// focus capability gate for "missing selection range" even though the caret is perfectly
    /// readable. The arithmetic lives in `MarkerSelectionSynthesizer`; this method only does the AX
    /// I/O and hands the three caret-adjacent text fragments to it.
    ///
    /// Returns nil (so the field stays unsupported, no regression) unless the full marker query
    /// surface is present and the before-caret text resolves, since that fragment drives the caret
    /// offset and a wrong offset would mis-split the model's context. Marker objects are treated as
    /// opaque `CFTypeRef`: never inspected, never cached across ticks or threads.
    static func synthesizeMarkerSelection(
        on element: AXUIElement,
        parameterizedAttributes: Set<String>
    ) -> MarkerSelection? {
        // Guard on advertised parameterized attributes so apps without marker support degrade to
        // nil instead of issuing doomed cross-process AX calls on every poll.
        guard parameterizedAttributes.contains(startMarkerForRangeAttribute as String),
            parameterizedAttributes.contains(endMarkerForRangeAttribute as String),
            parameterizedAttributes.contains(markerRangeForMarkersAttribute as String),
            parameterizedAttributes.contains(stringForMarkerRangeAttribute as String)
        else {
            return nil
        }

        guard let selectionRange = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
            let documentStart = copyOpaqueAttribute(startTextMarkerAttribute, on: element),
            let documentEnd = copyOpaqueAttribute(endTextMarkerAttribute, on: element),
            let selectionStart = copyOpaqueParameterized(
                startMarkerForRangeAttribute, parameter: selectionRange, on: element),
            let selectionEnd = copyOpaqueParameterized(
                endMarkerForRangeAttribute, parameter: selectionRange, on: element)
        else {
            return nil
        }

        // Before-caret text is required: its length is the caret offset. An empty-but-present
        // result (caret at document start) is valid; a failed query is not.
        guard let preRange = markerRange(from: documentStart, to: selectionStart, on: element),
            let beforeText = stringForMarkerRange(preRange, on: element)
        else {
            return nil
        }

        let selectedText = stringForMarkerRange(selectionRange, on: element) ?? ""

        // After-caret context is nice-to-have, not required for offset correctness.
        var afterText = ""
        if let postRange = markerRange(from: selectionEnd, to: documentEnd, on: element),
            let trailing = stringForMarkerRange(postRange, on: element) {
            afterText = trailing
        }

        return MarkerSelectionSynthesizer.make(
            beforeCaret: beforeText, selected: selectedText, afterCaret: afterText)
    }

    /// Builds an `AXTextMarkerRange` spanning two markers via `AXTextMarkerRangeForUnorderedTextMarkers`.
    private static func markerRange(
        from start: CFTypeRef, to end: CFTypeRef, on element: AXUIElement
    ) -> CFTypeRef? {
        let markers = [start, end] as CFArray
        return copyOpaqueParameterized(markerRangeForMarkersAttribute, parameter: markers, on: element)
    }

    /// Reads the plain text spanned by an opaque marker range.
    private static func stringForMarkerRange(_ range: CFTypeRef, on element: AXUIElement) -> String? {
        copyOpaqueParameterized(stringForMarkerRangeAttribute, parameter: range, on: element) as? String
    }

    /// Reads an attribute whose value is an opaque marker / marker-range object. Unlike the typed
    /// readers above, the value is returned without inspection because text markers are an opaque
    /// serialization that must only be passed back to other marker APIs.
    private static func copyOpaqueAttribute(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    /// Parameterized counterpart of `copyOpaqueAttribute` for marker queries.
    private static func copyOpaqueParameterized(
        _ attribute: CFString, parameter: CFTypeRef, on element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    /// Reads a raw AX attribute value and leaves type interpretation to the caller.
    /// This is the lowest-level helper in the file; the typed helpers above build on top of it.
    static func copyAttributeValue(_ attribute: CFString, on element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as AnyObject?
    }

    // MARK: - Tree Traversal

    /// Returns the currently focused UI element from the system-wide AX object.
    static func focusedElement() -> AXUIElement? {
        let systemWideElement = systemWideElement()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let element = value else {
            return nil
        }

        guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        // `AXUIElement` is a Core Foundation type, not a normal Swift class.
        // `unsafeBitCast` is appropriate here because we already verified the runtime type id.
        return unsafeBitCast(element, to: AXUIElement.self)
    }

    /// Returns the running application that owns the given AX element.
    ///
    /// This matters for accessory apps (Raycast, Spotlight, Alfred) that show non-activating
    /// panels: they keep the previously active app as `NSWorkspace.frontmostApplication` while
    /// actually owning the focused text element. Resolving identity from the element's pid is the
    /// only way to attribute the focused field to the real owner.
    static func owningApplication(of element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Returns the focused element scoped to a specific application process. Some web inputs that
    /// the system-wide focused-element query misses are reachable through the app-scoped query, so
    /// this is the intermediate link before falling back to cursor hit-testing.
    static func focusedElement(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, pollMessagingTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let element = value,
            CFGetTypeID(element) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(element, to: AXUIElement.self)
    }

    /// Sets `AXManualAccessibility` on an application's process element to wake a dormant web
    /// accessibility tree (Chromium/Electron build it lazily, only once an assistive client asks).
    ///
    /// Set on the **browser process** element only: renderer subprocesses have no OS-level AX
    /// element, and the composed tree lives in the browser process, which fans the request out to
    /// renderers over IPC. `AXManualAccessibility` is used in preference to `AXEnhancedUserInterface`
    /// because the latter has a documented side effect of glitching window managers. Returns the raw
    /// `AXError` so callers can distinguish "unsupported" (Electron builds that don't advertise it)
    /// from a transient failure worth retrying.
    @discardableResult
    static func setManualAccessibility(_ enabled: Bool, forApplicationPID pid: pid_t) -> AXError {
        guard pid > 0 else { return .failure }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, pollMessagingTimeout)
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, value)
    }

    /// Hit-tests the Accessibility tree at a Cocoa screen point (bottom-left origin) by converting
    /// to the top-left origin that `AXUIElementCopyElementAtPosition` expects.
    ///
    /// This is the only query that crosses Chrome's out-of-process-iframe boundary (the window
    /// server resolves on-screen geometry across processes), so it is the last resort for OOPIF
    /// editors like Gmail compose that surface through no focused-element attribute.
    static func element(atCocoaPoint point: CGPoint) -> AXUIElement? {
        // AX screen space is anchored to the top-left of the primary display (the screen at origin
        // (0,0), conventionally `screens.first`). Flipping against its height keeps multi-monitor
        // hit-tests correct because AX uses one global top-left origin.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }
        let axX = Float(point.x)
        let axY = Float(primaryHeight - point.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement(), axX, axY, &element) == .success else {
            return nil
        }
        return element
    }

    /// Reads whether an element currently holds focus. A cheap (single round-trip) re-validation for
    /// a cached hit-test element; a stale web handle returns false or errors, which callers treat as
    /// "re-resolve".
    static func isFocused(_ element: AXUIElement) -> Bool {
        boolValue(for: kAXFocusedAttribute as CFString, on: element) ?? false
    }

    /// Climbs at most `maxClimb` ancestors from a hit-test result to the nearest container that
    /// looks like an editable text target: a known editable role, an explicit editable flag, or a
    /// Chromium contenteditable that exposes the selected text-marker range. Returns the original
    /// element if none is found, leaving final candidate selection to `FocusSnapshotResolver`.
    static func nearestEditable(from element: AXUIElement, maxClimb: Int = 5) -> AXUIElement {
        var current = element
        for _ in 0...maxClimb {
            let role = stringValue(for: kAXRoleAttribute as CFString, on: current) ?? ""
            let attributes = Set(attributeNames(on: current))
            let explicitEditable =
                attributes.contains("AXEditable")
                ? boolValue(for: "AXEditable" as CFString, on: current) : nil
            if isKnownEditableRole(role)
                || hasStrongEditabilitySignal(role: role, explicitEditableFlag: explicitEditable)
                || attributes.contains(selectedTextMarkerRangeAttribute as String) {
                return current
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return element
    }

    /// Returns the parent AX node when the current element exposes one.
    static func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(kAXParentAttribute as CFString, on: element) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        // Same Core Foundation bridging rule as `focusedElement()`.
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Returns the immediate AX children for the current element.
    /// The result may be empty either because the node has no children or because the host app
    /// simply does not expose them through Accessibility.
    static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttributeValue(kAXChildrenAttribute as CFString, on: element) as? [AnyObject] else {
            return []
        }

        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            // Same Core Foundation bridging rule as `focusedElement()`.
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    static func elementIdentity(for element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return "\(pid)-\(CFHash(element))"
    }

    /// Builds a stable identifier for an AX element by combining bundle identity and AX identity.
    static func elementIdentifier(for element: AXUIElement, bundleIdentifier: String) -> String {
        "\(bundleIdentifier)-\(elementIdentity(for: element))"
    }

    // MARK: - Editability Heuristics

    static func editabilityHintScore(role: String, explicitEditableFlag: Bool?) -> Int {
        var score = 0

        if explicitEditableFlag == true {
            score += 10
        }

        if isKnownEditableRole(role) {
            score += 1
        }

        return score
    }

    /// A strong editability signal is what separates a real input target from display text that merely exposes AX metadata.
    static func hasStrongEditabilitySignal(role: String, explicitEditableFlag: Bool?) -> Bool {
        explicitEditableFlag == true || isKnownEditableRole(role)
    }

    static func isKnownEditableRole(_ role: String) -> Bool {
        knownEditableRoles.contains(role)
    }

    static func isKnownReadOnlyRole(_ role: String) -> Bool {
        knownReadOnlyRoles.contains(role)
    }

    // MARK: - Coordinate Conversion

    /// Converts raw Accessibility coordinates into global AppKit points via a per-display Y-flip.
    /// Use this for element-level rects (AXFrame) that are reliably in Cocoa points.
    /// For text-range rects (BoundsForRange, TextMarker), use `validatedCocoaTextRect` instead.
    static func cocoaRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        guard !rect.isNull, rect != .zero else {
            return rect
        }

        let displays = displayGeometries()
        if let converted = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: rect,
            displays: displays
        ) {
            return converted
        }

        return legacyDesktopUnionFlip(rect)
    }

    /// Converts a text-range AX rect to Cocoa coordinates, using the element's AXFrame (already
    /// in Cocoa coordinates) as a ground-truth anchor to detect whether pixel-to-point scaling
    /// is needed. This replaces the old bundle-ID heuristic with empirical geometric validation:
    ///   1. Y-flip the raw rect (no scaling) and check if it lands inside the anchor.
    ///   2. If not, divide by the Retina backing scale factor, Y-flip, and recheck.
    ///   3. Whichever version falls near the anchor wins. Falls back to unscaled if neither fits.
    static func validatedCocoaTextRect(
        fromAccessibilityRect textRect: CGRect,
        anchorFrame cocoaAnchorFrame: CGRect?
    ) -> CGRect {
        guard !textRect.isNull, textRect != .zero else {
            return textRect
        }

        let displays = displayGeometries()
        guard !displays.isEmpty else {
            return textRect
        }

        // Candidate A: plain Y-flip, assuming the AX rect is already in Cocoa points.
        let flipped = DisplayCoordinateConverter.appKitRect(
            fromCoreGraphicsRect: textRect,
            displays: displays
        ) ?? legacyDesktopUnionFlip(textRect)

        guard let anchor = cocoaAnchorFrame, !anchor.isEmpty else {
            // No anchor available — plain Y-flip is the safest default.
            return flipped
        }

        // Generous tolerance so padding, scrolling, and multi-line fields don't cause false negatives.
        let tolerance: CGFloat = 80
        let expandedAnchor = anchor.insetBy(dx: -tolerance, dy: -tolerance)

        if expandedAnchor.contains(CGPoint(x: flipped.midX, y: flipped.midY)) {
            return flipped
        }

        // Candidate B: some apps report text-range bounds in physical pixels on Retina screens.
        // Scale relative to the owning display's origin; dividing global coordinates directly
        // breaks when an external monitor has a non-zero or negative origin.
        for scaledFlipped in DisplayCoordinateConverter.appKitRectsFromPixelRect(
            textRect,
            displays: displays
        ) where expandedAnchor.contains(CGPoint(x: scaledFlipped.midX, y: scaledFlipped.midY)) {
            return scaledFlipped
        }

        // Neither candidate landed near the anchor. Return unscaled as best-effort.
        return flipped
    }

    private static func displayGeometries() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
            else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplayGeometry(
                appKitFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                coreGraphicsBounds: CGDisplayBounds(displayID),
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }

    /// Last-resort fallback for unusual virtual displays where AppKit cannot expose a display ID.
    private static func legacyDesktopUnionFlip(_ rect: CGRect) -> CGRect {
        let desktopBounds = NSScreen.screens
            .map(\.frame)
            .reduce(into: CGRect.null) { $0 = $0.union($1) }

        guard !desktopBounds.isNull else {
            return rect
        }

        return CGRect(
            x: rect.origin.x,
            y: desktopBounds.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
