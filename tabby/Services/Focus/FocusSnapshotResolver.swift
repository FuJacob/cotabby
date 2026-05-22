import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Resolves the most usable editable candidate around the current AX focus and materializes a
/// stable `FocusSnapshot`. This keeps AX candidate search and snapshot assembly separate from the
/// polling shell in `FocusTracker`.
@MainActor
struct FocusSnapshotResolver {
    private let geometryResolver: AXTextGeometryResolver

    init(geometryResolver: AXTextGeometryResolver? = nil) {
        self.geometryResolver = geometryResolver ?? AXTextGeometryResolver()
    }

    /// Resolves the best editable candidate around the focused AX node and materializes a focus snapshot.
    ///
    /// `focusChangeSequence` is a monotonic counter owned by `FocusTracker`. The resolver threads
    /// it into the resulting `FocusedInputSnapshot` so downstream consumers can detect field
    /// switches even when `CFHash`-based `elementIdentifier` collides across recycled AX nodes.
    func resolveSnapshot(
        focusedElement: AXUIElement,
        application: NSRunningApplication,
        focusChangeSequence: UInt64 = 0
    ) -> FocusSnapshot {
        let applicationName = application.localizedName ?? "Unknown"
        let bundleIdentifier = application.bundleIdentifier ?? "unknown.bundle"
        let focusedRole =
            AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) ?? "Unknown"
        let focusedSubrole = AXHelper.stringValue(
            for: kAXSubroleAttribute as CFString, on: focusedElement)
        let focusedElementIdentifier = AXHelper.elementIdentifier(
            for: focusedElement, bundleIdentifier: bundleIdentifier)

        let candidates = candidateElements(around: focusedElement).map {
            candidateSnapshot(for: $0, bundleIdentifier: bundleIdentifier)
        }
        let resolution = FocusCapabilityResolver.resolve(
            candidates: candidates.map(\.resolverCandidate))
        let selectedCandidate = resolution.bestDiagnosticCandidate.flatMap { candidate in
            candidates.first(where: { $0.elementIdentifier == candidate.elementIdentifier })
        }
        let inspection = FocusInspectionSnapshot(
            focusedElementIdentifier: focusedElementIdentifier,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            resolvedElementIdentifier: selectedCandidate?.elementIdentifier,
            resolvedRole: selectedCandidate?.role,
            resolvedSubrole: selectedCandidate?.subrole,
            missingCapabilities: resolution.resolvedCandidate == nil
                ? resolution.missingCapabilities : []
        )

        guard let resolvedCandidate = selectedCandidate,
            resolution.resolvedCandidate != nil
        else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported(resolution.unsupportedReason),
                context: nil,
                inspection: inspection
            )
        }

        guard let selection = resolvedCandidate.selection else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        guard selection.location >= 0, selection.length >= 0 else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range is invalid."),
                context: nil,
                inspection: inspection
            )
        }

        let value = resolvedCandidate.textValue ?? ""
        // `NSRange` coming from AX is expressed in UTF-16 code units, which is why the code below
        // uses `NSString` instead of slicing a native Swift `String` directly.
        guard selection.location <= value.utf16.count else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Selection range exceeds the current field value."),
                context: nil,
                inspection: inspection
            )
        }

        // The input target and the geometry source don't need to be the same element.
        // Native AppKit apps give exact caret rects on the input target itself. But Chrome
        // nests precise geometry on deep AXStaticText leaf nodes while the parent text entry
        // area only produces a coarse AXFrame estimate. When the primary candidate's geometry
        // is weak, search deeper for a leaf with exact caret data.
        let caretRect: CGRect
        let caretSource: String
        let caretQuality: CaretGeometryQuality
        let observedCharWidth: CGFloat?
        if let primary = resolvedCandidate.caretRect,
            resolvedCandidate.caretQuality == .exact || resolvedCandidate.caretQuality == .derived {
            caretRect = primary
            caretSource = "\(resolvedCandidate.caretQuality!.label) primary"
            caretQuality = resolvedCandidate.caretQuality!
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else if let deepResult = resolveDeepGeometrySource(
            focusedElement: focusedElement,
            resolvedElement: resolvedCandidate.element,
            cocoaAnchorFrame: resolvedCandidate.inputFrameRect
        ) {
            caretRect = deepResult.rect
            caretSource = "\(deepResult.quality.label) deep"
            caretQuality = deepResult.quality
            observedCharWidth = deepResult.observedCharWidth
        } else if let primary = resolvedCandidate.caretRect {
            caretRect = primary
            caretSource = "\(resolvedCandidate.caretQuality?.label ?? "unknown") primary-fallback"
            caretQuality = resolvedCandidate.caretQuality ?? .estimated
            observedCharWidth = resolvedCandidate.observedCharWidth
        } else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Caret bounds are unavailable."),
                context: nil,
                inspection: inspection
            )
        }

        let nsValue = value as NSString
        let safeSelectionLocation = min(selection.location, nsValue.length)
        let trailingStart = min(selection.location + selection.length, nsValue.length)
        let fieldContextText = combinedFieldContextText(
            directContext: resolvedCandidate.fieldContextText,
            nearbyContext: nearbyAccessibilityTextContext(
                around: resolvedCandidate.element,
                focusedTextValue: value
            )
        )
        let context = FocusedInputSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: Int32(application.processIdentifier),
            elementIdentifier: resolvedCandidate.elementIdentifier,
            role: resolvedCandidate.role,
            subrole: resolvedCandidate.subrole,
            caretRect: caretRect,
            inputFrameRect: resolvedCandidate.inputFrameRect,
            caretSource: caretSource,
            caretQuality: caretQuality,
            observedCharWidth: observedCharWidth,
            precedingText: nsValue.substring(to: safeSelectionLocation),
            trailingText: nsValue.substring(from: trailingStart),
            fieldContextText: fieldContextText,
            selection: selection,
            isSecure: resolvedCandidate.isSecure,
            focusChangeSequence: focusChangeSequence
        )

        if resolvedCandidate.isSecure {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Secure text input is active."),
                context: context,
                inspection: inspection
            )
        }

        if selection.length > 0 {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .blocked("Text is currently selected."),
                context: context,
                inspection: inspection
            )
        }

        return FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: .supported,
            context: context,
            inspection: inspection
        )
    }

    private func candidateElements(around focusedElement: AXUIElement) -> [AXUIElement] {
        var ordered: [AXUIElement] = []
        var seen = Set<String>()

        func append(_ element: AXUIElement?) {
            guard let element else {
                return
            }

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else {
                return
            }

            ordered.append(element)
        }

        append(focusedElement)

        var ancestors: [AXUIElement] = []
        var currentElement = focusedElement
        for _ in 0..<2 {
            guard let parent = AXHelper.parentElement(of: currentElement) else {
                break
            }

            ancestors.append(parent)
            append(parent)
            currentElement = parent
        }

        // The heuristic search order is:
        // 1. focused node
        // 2. a couple of ancestors
        // 3. children of those nodes
        //
        // This is a pragmatic compromise for apps that focus a wrapper element instead of the real
        // editable text node. We do not try to walk the entire AX tree.
        for node in [focusedElement] + ancestors {
            for child in AXHelper.childElements(of: node) {
                append(child)
            }
        }

        return ordered
    }

    /// Runs deep geometry search from the resolved editable candidate first, then falls back to
    /// the raw focused node when those are different branches of the same local AX neighborhood.
    private func resolveDeepGeometrySource(
        focusedElement: AXUIElement,
        resolvedElement: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CaretGeometryResult? {
        if let result = findDeepGeometrySource(
            from: resolvedElement,
            cocoaAnchorFrame: cocoaAnchorFrame
        ) {
            return result
        }

        guard
            AXHelper.elementIdentity(for: focusedElement)
                != AXHelper.elementIdentity(for: resolvedElement)
        else {
            return nil
        }

        return findDeepGeometrySource(
            from: focusedElement,
            cocoaAnchorFrame: cocoaAnchorFrame
        )
    }

    /// Searches deeper descendants of the focused element for a node with precise caret geometry.
    ///
    /// Chrome's AX tree nests live selection data on deep `AXStaticText` leaf nodes that have
    /// tight per-text-run frames — far more precise than the parent text entry area's AXFrame.
    /// We only read position from these nodes; the input target (where we type) stays unchanged.
    private func findDeepGeometrySource(
        from root: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CaretGeometryResult? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        let maxDepth = 10
        let maxNodes = 200
        var visited = 0
        var seen = Set<String>()
        var bestResult: (result: CaretGeometryResult, depth: Int)?

        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            // Look for any node with an active caret (zero-length selection).
            // Don't filter by role — Chrome uses AXStaticText for editable text runs.
            if let range = AXHelper.rangeValue(
                for: kAXSelectedTextRangeAttribute as CFString, on: element
            ), range.length == 0 {
                let paramAttrs = Set(AXHelper.parameterizedAttributeNames(on: element))
                let attrs = Set(AXHelper.attributeNames(on: element))
                let textValue =
                    attrs.contains(kAXValueAttribute as String)
                    ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
                    : nil
                let result = geometryResolver.resolveCaretRect(
                    for: element,
                    selection: range,
                    supportsBoundsForRange: paramAttrs.contains(
                        kAXBoundsForRangeParameterizedAttribute as String
                    ),
                    supportsFrame: attrs.contains("AXFrame"),
                    cocoaAnchorFrame: cocoaAnchorFrame,
                    textValue: textValue
                )

                if let result, result.quality == .exact || result.quality == .derived {
                    if shouldPreferDeepResult(
                        result,
                        at: depth,
                        over: bestResult
                    ) {
                        bestResult = (result, depth)
                    }
                }
            }

            guard depth < maxDepth else { continue }
            for child in AXHelper.childElements(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return bestResult?.result
    }

    /// Prefers deeper descendants because browser AX wrappers can expose superficially "valid"
    /// geometry on shallow nodes while the real caret anchor lives lower in the text-run leaves.
    private func shouldPreferDeepResult(
        _ candidate: CaretGeometryResult,
        at depth: Int,
        over best: (result: CaretGeometryResult, depth: Int)?
    ) -> Bool {
        guard let best else {
            return true
        }

        if depth != best.depth {
            return depth > best.depth
        }

        return deepResultQualityScore(candidate.quality)
            > deepResultQualityScore(best.result.quality)
    }

    private func deepResultQualityScore(_ quality: CaretGeometryQuality) -> Int {
        switch quality {
        case .exact:
            return 2
        case .derived:
            return 1
        case .estimated:
            return 0
        }
    }

    /// Extracts the AX properties Tabby needs from one candidate element near the current focus.
    private func candidateSnapshot(for element: AXUIElement, bundleIdentifier: String)
        -> AXFocusCandidate {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let supportedAttributes = Set(AXHelper.attributeNames(on: element))
        let supportedParameterizedAttributes = Set(
            AXHelper.parameterizedAttributeNames(on: element))
        let explicitEditableFlag =
            supportedAttributes.contains("AXEditable")
            ? AXHelper.boolValue(for: "AXEditable" as CFString, on: element)
            : nil
        let textValue =
            supportedAttributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        let selection =
            supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil
        var inputFrameRect =
            supportedAttributes.contains("AXFrame")
            ? geometryResolver.resolveInputFrameRect(for: element)
            : nil

        if let currentFrame = inputFrameRect {
            var finalWidth = currentFrame.width
            var finalX = currentFrame.minX

            // Optimization: grab the parent container's width if the active element is narrow
            // so we capture the whole input bar context (e.g. Discord/Slack dynamically sized nodes).
            if let parent = AXHelper.parentElement(of: element),
               let parentFrame = AXHelper.rectValue(for: "AXFrame" as CFString, on: parent) {
                let parentCocoa = AXHelper.cocoaRect(fromAccessibilityRect: parentFrame)
                if parentCocoa.width > finalWidth {
                    finalWidth = parentCocoa.width
                    finalX = parentCocoa.minX
                }
            }

            // Enforce a minimum width to ensure we get a decent horizontal slice.
            if finalWidth < 500 {
                finalWidth = max(finalWidth, 500)
            }

            inputFrameRect = CGRect(
                x: finalX,
                y: currentFrame.minY,
                width: finalWidth,
                height: currentFrame.height
            )
        }
        let caretResult = selection.flatMap {
            geometryResolver.resolveCaretRect(
                for: element,
                selection: $0,
                supportsBoundsForRange: supportedParameterizedAttributes.contains(
                    kAXBoundsForRangeParameterizedAttribute as String),
                supportsFrame: supportedAttributes.contains("AXFrame"),
                cocoaAnchorFrame: inputFrameRect,
                textValue: textValue
            )
        }
        let caretRect = caretResult?.rect
        let caretQuality = caretResult?.quality
        let isSecure = isSecureElement(element: element, role: role, subrole: subrole)
        let fieldContextText = focusedFieldContextText(
            for: element,
            textValue: textValue
        )
        let elementIdentifier = AXHelper.elementIdentifier(
            for: element, bundleIdentifier: bundleIdentifier)
        let resolverCandidate = FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: AXHelper.editabilityHintScore(
                role: role, explicitEditableFlag: explicitEditableFlag),
            hasStrongEditabilitySignal: AXHelper.hasStrongEditabilitySignal(
                role: role, explicitEditableFlag: explicitEditableFlag),
            isKnownReadOnlyRole: AXHelper.isKnownReadOnlyRole(role),
            hasTextValue: textValue != nil,
            hasSelectionRange: selection != nil,
            hasCaretBounds: caretRect != nil,
            isSecure: isSecure
        )

        return AXFocusCandidate(
            element: element,
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            textValue: textValue,
            selection: selection,
            caretRect: caretRect,
            caretQuality: caretQuality,
            observedCharWidth: caretResult?.observedCharWidth,
            inputFrameRect: inputFrameRect,
            fieldContextText: fieldContextText,
            isSecure: isSecure,
            resolverCandidate: resolverCandidate
        )
    }

    /// Extracts short field-level labels from Accessibility metadata.
    ///
    /// Many apps do not expose the surrounding document or conversation text through AX, but they do
    /// expose the active field's placeholder, title, description, or parent label. Keeping this as
    /// metadata separate from `textValue` prevents the typed user content from being duplicated while
    /// still giving autocomplete a stronger clue than just "App: Slack" or "App: Safari".
    private func focusedFieldContextText(
        for element: AXUIElement,
        textValue: String?
    ) -> String? {
        var pieces: [String] = []
        appendFieldMetadata(from: element, into: &pieces)

        if let parent = AXHelper.parentElement(of: element) {
            appendFieldMetadata(from: parent, into: &pieces)
        }

        let typedText = textValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPieces = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0 != typedText }

        var seen = Set<String>()
        let uniquePieces = normalizedPieces.filter { piece in
            seen.insert(piece.lowercased()).inserted
        }

        guard !uniquePieces.isEmpty else {
            return nil
        }

        let joined = uniquePieces.prefix(6).joined(separator: "\n")
        let sanitized = PromptContextSanitizer.sanitize(joined, maxCharacters: 500)
        return PromptContextSanitizer.containsAlphanumericSignal(sanitized) ? sanitized : nil
    }

    private func appendFieldMetadata(from element: AXUIElement, into pieces: inout [String]) {
        let metadataAttributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            "AXDOMIdentifier" as CFString
        ]

        for attribute in metadataAttributes {
            if let value = AXHelper.stringValue(for: attribute, on: element) {
                pieces.append(value)
            }
        }
    }

    /// Collects a small, ordered text excerpt from the AX neighborhood around the focused field.
    ///
    /// This is the low-latency alternative to asking a model to summarize a screenshot. It is bounded
    /// by ancestors, depth, node count, and character count so focus polling stays cheap enough for an
    /// autocomplete loop.
    private func nearbyAccessibilityTextContext(
        around element: AXUIElement,
        focusedTextValue: String
    ) -> String? {
        let root = nearbyContextRoot(for: element)
        let focusedText = focusedTextValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxDepth = 4
        let maxNodes = 140
        let maxCharacters = 1_200
        var visitedNodeCount = 0
        var seenElements = Set<String>()
        var seenText = Set<String>()
        var pieces: [String] = []
        var joinedCharacterCount = 0

        func appendText(_ rawText: String?) {
            guard let rawText else { return }

            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3,
                  text != focusedText,
                  !PromptContextSanitizer.isStandaloneUIMetadata(text),
                  PromptContextSanitizer.containsAlphanumericSignal(text)
            else {
                return
            }

            let key = text.lowercased()
            guard seenText.insert(key).inserted else {
                return
            }

            // Track the eventual joined length incrementally so the traversal can stop in O(1)
            // after each child visit instead of rebuilding the whole excerpt to measure it.
            joinedCharacterCount += text.count + (pieces.isEmpty ? 0 : 1)
            pieces.append(text)
        }

        func visit(_ current: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visitedNodeCount < maxNodes else {
                return
            }

            let identity = AXHelper.elementIdentity(for: current)
            guard seenElements.insert(identity).inserted else {
                return
            }

            visitedNodeCount += 1
            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: current)
            let attributes = Set(AXHelper.attributeNames(on: current))

            // Prefer display text and labels. Avoid pulling editable values from nested fields; those
            // are often unrelated drafts in complex web apps.
            if role == kAXStaticTextRole as String || role == "AXLink" || role == kAXButtonRole as String {
                appendText(AXHelper.stringValue(for: kAXValueAttribute as CFString, on: current))
            }

            appendText(AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: current))
            appendText(AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: current))

            if attributes.contains("AXPlaceholderValue") {
                appendText(AXHelper.stringValue(for: "AXPlaceholderValue" as CFString, on: current))
            }

            guard depth < maxDepth else {
                return
            }

            for child in AXHelper.childElements(of: current) {
                visit(child, depth: depth + 1)
                if joinedCharacterCount >= maxCharacters {
                    return
                }
            }
        }

        visit(root, depth: 0)

        let joined = pieces.joined(separator: "\n")
        let sanitized = PromptContextSanitizer.sanitize(joined, maxCharacters: maxCharacters)
        guard !sanitized.isEmpty,
              PromptContextSanitizer.containsAlphanumericSignal(sanitized)
        else {
            return nil
        }

        return sanitized
    }

    private func nearbyContextRoot(for element: AXUIElement) -> AXUIElement {
        var root = element
        var current = element

        // Two parent hops usually reaches the message/input container without walking an entire
        // browser window. The node/depth caps above are the real safety rail if an app exposes more.
        for _ in 0..<2 {
            guard let parent = AXHelper.parentElement(of: current) else {
                break
            }

            root = parent
            current = parent
        }

        return root
    }

    private func combinedFieldContextText(
        directContext: String?,
        nearbyContext: String?
    ) -> String? {
        let pieces = [directContext, nearbyContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else {
            return nil
        }

        var seen = Set<String>()
        let uniquePieces = pieces.filter { piece in
            seen.insert(piece.lowercased()).inserted
        }
        let sanitized = PromptContextSanitizer.sanitize(
            uniquePieces.joined(separator: "\n"),
            maxCharacters: 1_400
        )
        return PromptContextSanitizer.containsAlphanumericSignal(sanitized) ? sanitized : nil
    }

    /// Detects secure inputs so Tabby can intentionally refuse to operate in sensitive fields.
    private func isSecureElement(element: AXUIElement, role: String, subrole: String?) -> Bool {
        let secureMarkers = [
            role.lowercased(),
            subrole?.lowercased() ?? "",
            AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)?
                .lowercased() ?? "",
            AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)?.lowercased()
                ?? ""
        ]

        return secureMarkers.contains { marker in
            marker.contains("secure") || marker.contains("password")
        }
    }
}

/// AX data read from one candidate element near the current focus.
/// This keeps candidate search state local to the resolver instead of leaking it into the tracker.
private struct AXFocusCandidate {
    let element: AXUIElement
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let textValue: String?
    let selection: NSRange?
    let caretRect: CGRect?
    let caretQuality: CaretGeometryQuality?
    let observedCharWidth: CGFloat?
    let inputFrameRect: CGRect?
    let fieldContextText: String?
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
