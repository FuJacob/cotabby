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

    /// Reads an element's AX identifier (what `NSView.setAccessibilityIdentifier` surfaces). There is
    /// no public `kAX...` constant for it; the raw attribute name is "AXIdentifier". Used to recognise
    /// Cotabby's own sanctioned live-preview field so the focus pipeline can complete in it.
    static func accessibilityIdentifier(of element: AXUIElement) -> String? {
        stringValue(for: "AXIdentifier" as CFString, on: element)
    }

    /// Reads an array-of-strings AX attribute. Chromium/Electron exposes a web element's CSS
    /// classes through `AXDOMClassList` this way; native apps simply don't vend the attribute, so
    /// this returns nil for them rather than throwing.
    static func stringArrayValue(for attribute: CFString, on element: AXUIElement) -> [String]? {
        copyAttributeValue(attribute, on: element) as? [String]
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
    /// The `AXUIElement` a Core Foundation value holds, or nil when it holds anything else. The type
    /// check makes the bit cast safe: `AXUIElement` is a Core Foundation type.
    private static func axElement(from value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

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

    /// Reads a parameterized attribute that takes an integer (a line index or character offset) and
    /// returns an integer, such as `AXLineForIndex`. Nil when the host declines or answers with a
    /// non-numeric value.
    static func parameterizedIntValue(
        for attribute: CFString,
        parameter: Int,
        on element: AXUIElement
    ) -> Int? {
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, NSNumber(value: parameter), &value)
        guard result == .success, let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    /// Reads a parameterized attribute that takes an integer and returns a range, such as
    /// `AXRangeForLine`.
    static func parameterizedRangeValue(
        for attribute: CFString,
        parameter: Int,
        on element: AXUIElement
    ) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, NSNumber(value: parameter), &value)
        guard result == .success, let axValue = axValue(from: value), AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
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

    /// Reads a parameterized attributed-string range (e.g. `AXAttributedStringForRange`) so callers
    /// can inspect per-character styling such as font and foreground color without serializing the
    /// whole field. Returns nil for hosts that do not implement the attribute.
    static func parameterizedAttributedStringValue(
        for attribute: CFString,
        range: NSRange,
        on element: AXUIElement
    ) -> NSAttributedString? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value)
        guard result == .success, let value else { return nil }

        return value as? NSAttributedString
    }

    /// Resolves the focused field's own text font and color from Accessibility so ghost text can
    /// match the host instead of always rendering in the system font and a fixed gray.
    ///
    /// This is a single `AXAttributedStringForRange` read over one character near the caret. The font
    /// arrives either as a real `NSFont` under `.font` or as the AX font dictionary
    /// (`AXFontName`/`AXFontSize`); the color as an `NSColor` or a `CGColor` under the foreground key.
    /// Every path is optional and any miss returns nil, so callers fall back to default styling.
    ///
    /// Intended to be called once per focused-element identity (see `FieldStyleCache`); it is a
    /// synchronous cross-process AX call and must stay off the per-keystroke path.
    static func resolveFieldStyle(
        for element: AXUIElement,
        caretLocation: Int,
        textLength: Int
    ) -> ResolvedFieldStyle? {
        guard textLength > 0 else { return nil }

        // Prefer the character just before the caret (the text the user is extending), then the
        // first character. Clamp into range so an off-by-one caret never reads out of bounds.
        let clampedCaret = min(max(caretLocation - 1, 0), textLength - 1)
        let candidateIndices = clampedCaret == 0 ? [0] : [clampedCaret, 0]

        for index in candidateIndices {
            guard let attributed = parameterizedAttributedStringValue(
                for: "AXAttributedStringForRange" as CFString,
                range: NSRange(location: index, length: 1),
                on: element
            ), attributed.length > 0 else {
                continue
            }

            let attributes = attributed.attributes(at: 0, effectiveRange: nil)
            if let style = fieldStyle(from: attributes) {
                return style
            }
        }

        return nil
    }

    /// Extracts a `ResolvedFieldStyle` from one character's attributes, handling both the AppKit
    /// `.font`/`.foregroundColor` shapes and the AX-specific font dictionary / `CGColor` shapes.
    private static func fieldStyle(from attributes: [NSAttributedString.Key: Any]) -> ResolvedFieldStyle? {
        var fontName: String?
        var fontFamily: String?
        var fontPointSize: CGFloat?
        if let font = attributes[.font] as? NSFont {
            fontName = font.fontName
            fontFamily = font.familyName
            fontPointSize = font.pointSize
        } else if let fontInfo = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
            // AppKit hosts vend name, family, and size. Chromium vends only the size (its inline
            // text boxes carry no face), which is still the single most useful fact for matching.
            fontName = fontInfo["AXFontName"] as? String
            fontFamily = fontInfo["AXFontFamily"] as? String
            if let size = fontInfo["AXFontSize"] as? NSNumber {
                fontPointSize = CGFloat(size.doubleValue)
            }
        }

        var colorHex: String?
        if let nsColor = attributes[.foregroundColor] as? NSColor {
            colorHex = SuggestionTextColorCodec.hexString(from: nsColor)
        } else if let foreground = attributes[.foregroundColor],
                  CFGetTypeID(foreground as CFTypeRef) == CGColor.typeID {
            // AX often reports the foreground as a CGColor. A conditional `as? CGColor` does not
            // compile against `Any` (the compiler treats the CF downcast as always-succeeding), so we
            // verify the CF type id and force-cast. Unlike `unsafeBitCast`, this keeps normal ARC
            // ownership and cannot fail given the verified type id.
            // swiftlint:disable:next force_cast
            let cgColor = foreground as! CGColor
            if let nsColor = NSColor(cgColor: cgColor) {
                colorHex = SuggestionTextColorCodec.hexString(from: nsColor)
            }
        }

        let style = ResolvedFieldStyle(
            fontName: fontName,
            fontFamily: fontFamily,
            fontPointSize: fontPointSize,
            colorHex: colorHex
        )
        return style.isEmpty ? nil : style
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
    private static let lineRangeForMarkerAttribute = "AXLineTextMarkerRangeForTextMarker" as CFString
    private static let previousMarkerAttribute = "AXPreviousTextMarkerForTextMarker" as CFString
    private static let nextMarkerAttribute = "AXNextTextMarkerForTextMarker" as CFString
    private static let elementForMarkerAttribute = "AXUIElementForTextMarker" as CFString
    private static let boundsForMarkerRangeAttribute = "AXBoundsForTextMarkerRange" as CFString
    /// Characters a rendered bullet-list marker is made of, as it appears in a line's marker text.
    private static let bulletMarkerCharacters: Set<Character> = ["\u{2022}", "\u{25E6}", "\u{25AA}", "\u{2023}", "\u{2043}"]

    /// The caret's visual line read through the text-marker API.
    struct MarkerLineGeometry {
        /// The caret line's box, starting at its first text character, in Accessibility (top-left
        /// origin) coordinates.
        let line: CGRect
        /// The box of the line above, only when it belongs to the same text element: the distance
        /// between the two is then the paragraph's own line pitch, never a gap between paragraphs.
        let previousLine: CGRect?
        /// The glyph box of the caret line's first character (past a list marker), when the line has
        /// one. A line range's own box can be its paragraph's padded block: Claude's composer
        /// answered x 84 for text at 95 and 33pt for 20pt glyph lines (2026-09-11), and a two-line
        /// paragraph's box was taller than any line.
        let firstCharacter: CGRect?
        /// The glyph box of the first character of the line above, under the same conditions as
        /// `previousLine`: with `firstCharacter` it measures the pitch between two glyph boxes.
        let previousFirstCharacter: CGRect?
        /// The frame of the element around the caret's text (its paragraph), for a line with text,
        /// when that element is not the field itself. In a ProseMirror-style editor (a <p> per
        /// paragraph, no padding) a one-line paragraph's frame is the line box: 21pt around a 17pt
        /// glyph box in a ProseMirror-style page, 14px at line-height 1.5 (2026-09-11). Whether it is a
        /// line box is `HostTextMetricsProbe.paragraphLinePitch`'s to judge.
        var paragraph: CGRect?
    }

    /// Line ranges a caret line may be split into before the walk back to its start gives up (see
    /// `textMarkerCaretLine`): a line holds a handful of inline elements, not dozens.
    static let maximumLineFragments = 8

    /// Whether `range`, the box of the line range just before a line range's start, is an earlier
    /// part of the same visual line rather than the line above: on the line (its middle within half
    /// a glyph box of the line's first glyph), starting left of that glyph and ending at it (within
    /// a glyph box: a column further left is another text), and no taller than two glyph boxes.
    static func isEarlierFragment(_ range: CGRect, ofLineStartingAt first: CGRect) -> Bool {
        abs(range.midY - first.midY) < first.height / 2
            && range.minX < first.minX - 0.5
            && abs(range.maxX - first.minX) <= first.height
            && range.height <= first.height * 2
    }

    /// The caret's visual line for a host whose index-based bounds answer nothing (a Chromium
    /// contenteditable such as Claude's composer), read through text markers: the caret marker's
    /// line range and its box, and the box of the line above it.
    ///
    /// Why: a wrapped ghost row starts where the host starts its next line. Without this the row
    /// started at the frame's assumed 4pt inset, 7pt left of Claude's text, and stepped down by the
    /// 19pt caret box instead of the 23pt line (measured 2026-09-10). Markers stay opaque here as
    /// everywhere: only passed back to the element that vended them.
    static func textMarkerCaretLine(on element: AXUIElement, parameterizedAttributes: Set<String>) -> MarkerLineGeometry? {
        // Only the line query must be advertised: Chromium answers `AXBoundsForTextMarkerRange`
        // without listing it (the caret itself comes from it), and splits ranges only through
        // HIServices on some elements (see `startMarker(of:on:attributes:)`).
        guard parameterizedAttributes.contains(lineRangeForMarkerAttribute as String),
              let selection = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
              let caret = startMarker(of: selection, on: element, attributes: parameterizedAttributes),
              let lineRange = copyOpaqueParameterized(lineRangeForMarkerAttribute, parameter: caret, on: element),
              let lineStart = startMarker(of: lineRange, on: element, attributes: parameterizedAttributes)
        else {
            return nil
        }
        let lineText = stringForMarkerRange(lineRange, on: element) ?? ""
        // The line's first glyph, past a list item's marker ("• "): its box is where the line's text
        // starts and how tall a line of it is, whatever box the host gives the whole range.
        var firstCharacter = lineText.isEmpty ? nil : characterBox(
            from: lineStart, advancing: textOffsetPastBullet(lineText) ?? 0, on: element, attributes: parameterizedAttributes
        )
        // An empty line has no box of its own; the caret sits at its start, so its box is the edge.
        guard var line = markerRangeRect(lineRange, on: element, requiresWidth: !lineText.isEmpty)
            ?? (lineText.isEmpty ? markerRangeRect(selection, on: element, requiresWidth: false) : nil)
            ?? firstCharacter
        else {
            return nil
        }
        if let left = firstCharacter?.minX, left > line.minX {
            line = CGRect(x: left, y: line.minY, width: max(0, line.maxX - left), height: line.height)
        }
        // The line above is the line of the character just before this line's start. (Asked for
        // the previous line start from a line start, Chrome answered this line's own start, 2026-09-10.)
        // Chromium can also end a line range partway along its visual line, at an inline element's
        // edge: in Gmail's compose body (2026-09-11) the caret line's range started at x 804, then
        // 743, on a line whose text starts at 393, and every wrapped ghost row started there. The
        // range before such a start lies on the same visual line (`isEarlierFragment`); those are
        // walked back over, and the first range before that is another line is the line above.
        var start = lineStart
        var previous: CGRect?
        var previousFirst: CGRect?
        var fragments = 0
        while let before = copyOpaqueParameterized(previousMarkerAttribute, parameter: start, on: element),
              let previousRange = copyOpaqueParameterized(lineRangeForMarkerAttribute, parameter: before, on: element),
              let previousStart = startMarker(of: previousRange, on: element, attributes: parameterizedAttributes) {
            let previousRect = markerRangeRect(previousRange, on: element, requiresWidth: true)
            let previousText = stringForMarkerRange(previousRange, on: element) ?? ""
            func previousGlyph() -> CGRect? {
                previousText.isEmpty ? nil : characterBox(
                    from: previousStart, advancing: textOffsetPastBullet(previousText) ?? 0,
                    on: element, attributes: parameterizedAttributes
                )
            }
            if fragments < maximumLineFragments, let first = firstCharacter, let rect = previousRect,
               isEarlierFragment(rect, ofLineStartingAt: first) {
                // The line starts at the fragment's first glyph, on the caret line's glyph row.
                let glyph = previousGlyph()
                let left = min(glyph?.minX ?? rect.minX, first.minX)
                line = CGRect(x: left, y: line.minY, width: max(0, line.maxX - left), height: line.height)
                firstCharacter = CGRect(x: left, y: first.minY, width: glyph?.width ?? first.width, height: first.height)
                start = previousStart
                fragments += 1
                continue
            }
            if sameTextElement(start, previousStart, on: element, attributes: parameterizedAttributes) {
                if let rect = previousRect, rect.minY < line.minY - 1 {
                    previous = rect
                }
                if let first = firstCharacter, let box = previousGlyph(), box.minY < first.minY - 1 {
                    previousFirst = box
                }
            }
            break
        }
        // The paragraph around the caret's text: the parent of the text element the caret marker is
        // in, unless that parent is the field (text straight inside a contenteditable has no
        // paragraph of its own, and the field's frame holds its padding).
        var paragraph: CGRect?
        if !lineText.isEmpty, parameterizedAttributes.contains(elementForMarkerAttribute as String),
           let textElement = axElement(from: copyOpaqueParameterized(elementForMarkerAttribute, parameter: caret, on: element)) {
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(textElement, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = axElement(from: parentRef), !CFEqual(parent, element) {
                paragraph = accessibilityFrame(of: parent)
            }
        }
        return MarkerLineGeometry(
            line: line, previousLine: previous, firstCharacter: firstCharacter, previousFirstCharacter: previousFirst,
            paragraph: paragraph
        )
    }

    /// An element's frame from its position and size, in Accessibility (top-left origin) coordinates;
    /// nil when either is missing or the size is empty.
    private static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = axValue(from: positionRef), let sizeValue = axValue(from: sizeRef)
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        // `AXValueGetValue` reports false for a wrong payload type.
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// The first marker of an opaque range: through the element's own query when it advertises one,
    /// else HIServices' splitter, the path `synthesizeMarkerSelection` takes for the same hosts
    /// (measured 2026-09-10: Chrome's contenteditable answered no `AXStartTextMarkerForTextMarkerRange`,
    /// so the line box never formed until this fallback).
    private static func startMarker(of range: CFTypeRef, on element: AXUIElement, attributes: Set<String>) -> CFTypeRef? {
        if attributes.contains(startMarkerForRangeAttribute as String),
           let start = copyOpaqueParameterized(startMarkerForRangeAttribute, parameter: range, on: element) {
            return start
        }
        return MarkerRangeSplitter.startMarker(of: range)
    }

    /// The box `AXBoundsForTextMarkerRange` gives for an opaque marker range, when it is a real one.
    private static func markerRangeRect(_ range: CFTypeRef, on element: AXUIElement, requiresWidth: Bool) -> CGRect? {
        guard let value = copyOpaqueParameterized(boundsForMarkerRangeAttribute, parameter: range, on: element),
              let bounds = axValue(from: value), AXValueGetType(bounds) == .cgRect
        else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds, .cgRect, &rect), rectHasFiniteComponents(rect), rect.height > 0 else {
            return nil
        }
        return requiresWidth && rect.width <= 0 ? nil : rect
    }

    /// Characters to skip past a leading bullet and its spacing, or nil when the line has none.
    private static func textOffsetPastBullet(_ lineText: String) -> Int? {
        let characters = Array(lineText)
        guard let first = characters.first, bulletMarkerCharacters.contains(first) else { return nil }
        var index = 1
        guard index < characters.count, characters[index].isWhitespace else { return nil }
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        return index < characters.count && index <= 8 ? index : nil
    }

    /// The glyph box of the character `count` markers after `start`, in Accessibility coordinates.
    private static func characterBox(
        from start: CFTypeRef, advancing count: Int, on element: AXUIElement, attributes: Set<String>
    ) -> CGRect? {
        guard attributes.contains(nextMarkerAttribute as String) else { return nil }
        var marker = start
        for _ in 0..<count {
            guard let next = copyOpaqueParameterized(nextMarkerAttribute, parameter: marker, on: element) else { return nil }
            marker = next
        }
        guard let after = copyOpaqueParameterized(nextMarkerAttribute, parameter: marker, on: element),
              let range = markerRange(from: marker, to: after, on: element),
              let rect = markerRangeRect(range, on: element, requiresWidth: true)
        else {
            return nil
        }
        return rect
    }

    /// Whether two markers sit in the same text element (one paragraph's text node).
    private static func sameTextElement(
        _ first: CFTypeRef, _ second: CFTypeRef, on element: AXUIElement, attributes: Set<String>
    ) -> Bool {
        guard attributes.contains(elementForMarkerAttribute as String),
              let firstElement = copyOpaqueParameterized(elementForMarkerAttribute, parameter: first, on: element),
              let secondElement = copyOpaqueParameterized(elementForMarkerAttribute, parameter: second, on: element)
        else {
            return false
        }
        return CFEqual(firstElement, secondElement)
    }

    /// Whether the element reads its text through text markers (a WebKit or Chromium web area).
    static func readsTextMarkers(parameterizedAttributes: Set<String>) -> Bool {
        parameterizedAttributes.contains(stringForMarkerRangeAttribute as String)
    }

    /// Whether the caret sits at the start of a text block (a paragraph, a list item) rather than at
    /// the end of the block before it. Chromium's range offsets count both spots as one (see
    /// `BlockBreakAlignment`); its text markers keep them apart. Measured 2026-09-11 in a
    /// ProseMirror page modelled on Claude's composer: at a paragraph's start the caret's marker names that
    /// paragraph's text and the marker before it another element; at the end of the paragraph
    /// before, both name that paragraph's text; in an empty paragraph the caret's marker names the
    /// paragraph's group. False whenever the markers cannot answer, which leaves the caret where the
    /// range offset put it.
    static func caretStartsTextBlock(on element: AXUIElement, parameterizedAttributes: Set<String>) -> Bool {
        guard parameterizedAttributes.contains(elementForMarkerAttribute as String),
              let selection = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
              let caret = startMarker(of: selection, on: element, attributes: parameterizedAttributes),
              let previous = copyOpaqueParameterized(previousMarkerAttribute, parameter: caret, on: element),
              let caretElement = copyOpaqueParameterized(elementForMarkerAttribute, parameter: caret, on: element),
              let previousElement = copyOpaqueParameterized(elementForMarkerAttribute, parameter: previous, on: element)
        else {
            return false
        }
        return !CFEqual(caretElement, previousElement)
    }

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
        // nil instead of issuing doomed cross-process AX calls on every poll. Chromium advertises
        // the two range-splitting queries; WebKit's web areas answer them with
        // kAXErrorParameterizedAttributeUnsupported (Mail's compose body, measured 2026-09-10) and
        // are split with HIServices' own functions instead (`MarkerRangeSplitter`).
        let splitsRangesItself = parameterizedAttributes.contains(startMarkerForRangeAttribute as String)
            && parameterizedAttributes.contains(endMarkerForRangeAttribute as String)
        guard splitsRangesItself || MarkerRangeSplitter.isAvailable,
            parameterizedAttributes.contains(markerRangeForMarkersAttribute as String),
            parameterizedAttributes.contains(stringForMarkerRangeAttribute as String)
        else {
            return nil
        }

        guard let selectionRange = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
            let documentStart = copyOpaqueAttribute(startTextMarkerAttribute, on: element),
            let documentEnd = copyOpaqueAttribute(endTextMarkerAttribute, on: element)
        else {
            return nil
        }
        let selectionStart: CFTypeRef
        let selectionEnd: CFTypeRef
        if splitsRangesItself,
            let start = copyOpaqueParameterized(startMarkerForRangeAttribute, parameter: selectionRange, on: element),
            let end = copyOpaqueParameterized(endMarkerForRangeAttribute, parameter: selectionRange, on: element) {
            selectionStart = start
            selectionEnd = end
        } else if let start = MarkerRangeSplitter.startMarker(of: selectionRange),
            let end = MarkerRangeSplitter.endMarker(of: selectionRange) {
            selectionStart = start
            selectionEnd = end
        } else {
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

    /// Sets `AXEnhancedUserInterface` on an application's process element: the flag VoiceOver sets,
    /// which Chromium treats as "a screen reader is present" and answers by building its complete
    /// accessibility tree, inline text boxes included. Returns true when the flag reads back as set,
    /// because Chrome reports an error code for the write even as it honors it.
    static func setEnhancedUserInterface(_ enabled: Bool, forApplicationPID pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, pollMessagingTimeout)
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        let attribute = "AXEnhancedUserInterface" as CFString
        let result = AXUIElementSetAttributeValue(appElement, attribute, value)
        if result == .success {
            return true
        }
        return boolValue(for: attribute, on: appElement) == enabled
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
        let accessibilityPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        return element(atAccessibilityPoint: accessibilityPoint)
    }

    /// Hit-tests an Accessibility element from Quartz/CGEvent global coordinates (top-left origin).
    ///
    /// Global input taps already report points in AX screen space, so converting those points through
    /// Cocoa would introduce an unnecessary second coordinate flip. Calendar's interaction guard uses
    /// this overload directly from the listen-only pointer event callback.
    static func element(atAccessibilityPoint point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement(), Float(point.x), Float(point.y), &element
        ) == .success else {
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

    /// Best-effort, fail-safe read of the title of the window containing `element`. Most apps vend
    /// `kAXWindowAttribute` directly on any descendant element; when that misses, nil is returned
    /// rather than walking the tree, so the read stays a single bounded round-trip on the focus
    /// path. Used for surface conditioning (the title carries the email subject, document name,
    /// channel, or page title) and cached per field session by the caller.
    static func windowTitle(near element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(kAXWindowAttribute as CFString, on: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // Same Core Foundation bridging rule as `parentElement(of:)`.
        let window = unsafeBitCast(value, to: AXUIElement.self)
        return stringValue(for: kAXTitleAttribute as CFString, on: window)
    }

    /// Best-effort, fail-safe read of the web page URL near `element`, used only for per-site rules.
    /// Browsers expose `kAXURLAttribute` on the web area or window rather than the focused field, so
    /// this walks up a bounded number of ancestors. It returns nil on any miss (non-browser focus, an
    /// app that does not expose the attribute, or the climb running out), so a failed read degrades to
    /// "no per-site rule applies" rather than misbehaving. It never mutates AX state.
    static func webURL(near element: AXUIElement, maxClimb: Int = 6) -> String? {
        var current = element
        for _ in 0...maxClimb {
            if let url = urlString(on: current) {
                return url
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    /// Reads `kAXURLAttribute` as a string, tolerating the value arriving as a `URL`/`NSURL` (the
    /// usual case) or already as a string.
    private static func urlString(on element: AXUIElement) -> String? {
        guard let value = copyAttributeValue(kAXURLAttribute as CFString, on: element) else {
            return nil
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        if let url = value as? NSURL {
            return url.absoluteString
        }
        return value as? String
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

    /// Locates the app's "Paste" menu item by its Cmd-V key equivalent rather than by title, so the
    /// lookup is language-independent ("Paste" / "貼り付け" / "Coller" depending on the host's
    /// localization). The IME-safe insertion path presses this real menu item via `AXPress`: the
    /// host runs its paste command without any key event existing, so an active input method can
    /// neither swallow nor re-interpret the commit the way it does a synthetic keystroke.
    static func pasteMenuItem(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, pollMessagingTimeout)
        guard let menuBarValue = copyAttributeValue(kAXMenuBarAttribute as CFString, on: appElement),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return nil
        }
        // Same Core Foundation bridging rule as `focusedElement()`.
        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)

        // Menu bar -> top-level items (Apple, app, File, Edit, ...) -> one AXMenu each -> menu items.
        // Depth-1 only: Paste always lives directly in a top-level menu, and skipping submenu
        // recursion keeps the walk bounded. Early exit on the first Cmd-V item.
        //
        // Every walked element gets the short poll timeout before it is messaged: the walk runs on
        // the main actor inside the accept path, and an element handle that never had a timeout set
        // would otherwise fall back to the multi-second AX default if the host (a busy Chromium
        // process is the common case here) stalls, beachballing typing for the duration.
        AXUIElementSetMessagingTimeout(menuBar, pollMessagingTimeout)
        for topLevelItem in childElements(of: menuBar) {
            AXUIElementSetMessagingTimeout(topLevelItem, pollMessagingTimeout)
            for menu in childElements(of: topLevelItem) {
                AXUIElementSetMessagingTimeout(menu, pollMessagingTimeout)
                for item in childElements(of: menu) where isCommandVMenuItem(item) {
                    return item
                }
            }
        }
        return nil
    }

    /// True for a menu item whose key equivalent is exactly Cmd-V. `kAXMenuItemCmdModifiers` uses the
    /// Carbon menu encoding where 0 means "Command alone"; shift/option/control add bits and 8 means
    /// the equivalent carries no Command at all, so only an exact 0 matches plain Cmd-V. A missing
    /// modifiers attribute rejects the item explicitly rather than relying on `nil == 0` being false.
    private static func isCommandVMenuItem(_ item: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(item, pollMessagingTimeout)
        guard let cmdChar = stringValue(for: kAXMenuItemCmdCharAttribute as CFString, on: item),
              cmdChar.uppercased() == "V" else {
            return false
        }
        guard let modifiers = intValue(for: kAXMenuItemCmdModifiersAttribute as CFString, on: item) else {
            return false
        }
        return modifiers == 0
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
        guard rectHasFiniteComponents(rect) else {
            return .zero
        }
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

    /// True only when every component of `rect` is a finite number. Some host AX implementations
    /// (Chromium/Electron, especially mid-scroll or under load) return NaN/Inf bounds; AppKit raises
    /// on a non-finite window frame and `Int(.nan)` traps, so such rects are rejected here at the AX
    /// ingest boundary before they can reach geometry math or `NSWindow.setFrame`.
    static func rectHasFiniteComponents(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
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
        guard rectHasFiniteComponents(textRect) else {
            return .zero
        }
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

    /// Cached display list. Display configuration changes are rare (plug/unplug, resolution or
    /// arrangement changes), but `cocoaRect`/`validatedCocoaTextRect` run for every AX rect at the
    /// focus-poll cadence — rebuilding `NSScreen.screens` + `CGDisplayBounds` per conversion
    /// multiplied AppKit/CoreGraphics traffic by the resolve rate for identical results. All AX
    /// geometry work happens on the main thread, so unsynchronized statics are safe here.
    private static var cachedDisplayGeometries: [DisplayGeometry]?

    /// Invalidation hook for the cache above. macOS posts `didChangeScreenParameters` for every
    /// event that can alter the display list (connect/disconnect, resolution, arrangement, Dock
    /// and menu-bar resizes affecting `visibleFrame`). Lazily installed via the first
    /// `displayGeometries()` call, so the observer always exists before a cached value could go
    /// stale.
    private static let displayChangeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
    ) { _ in
        cachedDisplayGeometries = nil
    }

    private static func displayGeometries() -> [DisplayGeometry] {
        _ = displayChangeObserver
        if let cachedDisplayGeometries {
            return cachedDisplayGeometries
        }

        let geometries = NSScreen.screens.compactMap { screen -> DisplayGeometry? in
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
        cachedDisplayGeometries = geometries
        return geometries
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

/// File-local bridge to two HIServices functions that split an `AXTextMarkerRange` into its
/// markers: `AXTextMarkerRangeCopyStartMarker` and `AXTextMarkerRangeCopyEndMarker`. They ship in
/// HIServices (VoiceOver uses them) but are not in the public headers, so they are resolved once
/// with `dlsym` and called through C function types.
///
/// Why: WebKit's editable web areas (Mail's compose body) vend the selection only as a marker
/// range and refuse the parameterized attributes that would split it, while Chromium answers
/// them. Without the split there is no before-caret text and no caret offset, and the resolver
/// falls back to whichever header field happens to be capable. The returned markers are +1
/// retained CF objects (the Copy rule) and are handed straight back to other marker queries; they
/// are never inspected. On a system without the symbols `isAvailable` is false and the synthesis
/// declines exactly as it did before.
enum MarkerRangeSplitter {
    private typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?

    private static let copyStart: CopyMarker? = load("AXTextMarkerRangeCopyStartMarker")
    private static let copyEnd: CopyMarker? = load("AXTextMarkerRangeCopyEndMarker")

    static var isAvailable: Bool { copyStart != nil && copyEnd != nil }

    static func startMarker(of range: CFTypeRef) -> CFTypeRef? {
        copyStart?(range)?.takeRetainedValue()
    }

    static func endMarker(of range: CFTypeRef) -> CFTypeRef? {
        copyEnd?(range)?.takeRetainedValue()
    }

    /// `dlsym` against the whole process image: HIServices is already loaded through
    /// ApplicationServices, so no `dlopen` is needed. `unsafeBitCast` reinterprets the raw symbol
    /// address as the C function type; that is the standard (and only) way to call an unexported
    /// C function from Swift.
    private static func load(_ name: String) -> CopyMarker? {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: CopyMarker.self)
    }
}
