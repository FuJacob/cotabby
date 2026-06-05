import ApplicationServices
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Resolves the best editable AX candidate around the current focus and reads its per-element AX
/// data. It searches the local AX neighborhood (the focused node, a couple of ancestors, their
/// children, plus a bounded editable-descendant BFS for Chromium/Electron), reads each candidate's
/// text/selection/caret data, and returns the first fully-capable target (or the best partial, for
/// diagnostics).
///
/// Split out of `FocusSnapshotResolver` so candidate search and per-element AX reads stay separate
/// from snapshot assembly. Holds a `CaretGeometryResolver` for caret and input-frame geometry.
@MainActor
struct FocusCandidateResolver {
    private let geometryResolver: CaretGeometryResolver

    /// Maximum UTF-16 units kept on each side of the caret when reading a native text window.
    /// `FocusSnapshotResolver.boundedContextWindow` re-bounds the snapshot text to the same width,
    /// so the two must stay in sync.
    static let focusedTextContextWindowUTF16 = 4096

    init(geometryResolver: CaretGeometryResolver? = nil) {
        // Construct the default inside the actor-isolated body: Swift evaluates default parameter
        // expressions before entering the `@MainActor` context, so a `= CaretGeometryResolver()`
        // default would be a nonisolated call to a main-actor-isolated initializer.
        self.geometryResolver = geometryResolver ?? CaretGeometryResolver()
    }

    /// Resolves candidate elements lazily and stops as soon as the first fully capable editable
    /// target is found.
    ///
    /// The old eager map built an `AXFocusCandidate` for every nearby Chromium node before asking
    /// `FocusCapabilityResolver` to pick the first supported one. In large web editors that meant
    /// reading text/selection/caret data from many wrapper and static-text nodes even after the real
    /// input target had already been discovered. This preserves the resolver's "first full
    /// capability wins" policy while avoiding unnecessary synchronous AX IPC.
    func resolve(
        around focusedElement: AXUIElement,
        bundleIdentifier: String,
        deepDescendants: Bool
    ) -> FocusCandidateResolution {
        var bestPartial: (candidate: AXFocusCandidate, evaluation: FocusCapabilityCandidateEvaluation)?
        var inspectedCount = 0

        for element in candidateElements(around: focusedElement, deepDescendants: deepDescendants) {
            inspectedCount += 1
            let candidate = candidateSnapshot(for: element, bundleIdentifier: bundleIdentifier)
            let evaluation = FocusCapabilityResolver.evaluate(candidate.resolverCandidate)

            if evaluation.hasFullCapabilities {
                return FocusCandidateResolution(
                    resolvedCandidate: candidate,
                    diagnosticCandidate: candidate,
                    resolution: FocusCapabilityResolution(
                        selectedEvaluation: evaluation,
                        inspectedCandidateCount: inspectedCount
                    )
                )
            }

            if bestPartial == nil || evaluation.score > bestPartial!.evaluation.score {
                bestPartial = (candidate, evaluation)
            }
        }

        return FocusCandidateResolution(
            resolvedCandidate: nil,
            diagnosticCandidate: bestPartial?.candidate,
            resolution: FocusCapabilityResolution(
                selectedEvaluation: bestPartial?.evaluation,
                inspectedCandidateCount: inspectedCount
            )
        )
    }

    private func candidateElements(
        around focusedElement: AXUIElement, deepDescendants: Bool = false
    ) -> [AXUIElement] {
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

        // Chromium reports focus on a wrapper above the editable (AXWebArea → AXGroup → … →
        // AXTextField), so the shallow walk above can miss the real target. Search descendants for
        // editable-looking nodes, bounded in depth and count and appending only likely editables
        // (not every visited node) so per-tick candidateSnapshot cost stays in check.
        if deepDescendants {
            appendEditableDescendants(of: [focusedElement] + ancestors, append: append)
        }

        return ordered
    }

    /// Bounded BFS for editable-looking descendants, used only for Chromium/Electron. Traverses up
    /// to `maxVisits` nodes / `maxDepth` deep but appends at most `maxAppended` likely-editable
    /// nodes, keeping the downstream snapshotting cost roughly constant.
    private func appendEditableDescendants(
        of roots: [AXUIElement], append: (AXUIElement?) -> Void
    ) {
        let maxDepth = 6
        let maxVisits = 200
        let maxAppended = 12
        var visited = 0
        var appended = 0
        var seenIdentity = Set<String>()
        var queue: [(element: AXUIElement, depth: Int)] = roots.map { ($0, 0) }

        while !queue.isEmpty, visited < maxVisits, appended < maxAppended {
            let (element, depth) = queue.removeFirst()
            guard seenIdentity.insert(AXHelper.elementIdentity(for: element)).inserted else {
                continue
            }
            visited += 1

            if looksEditable(element) {
                append(element)
                appended += 1
            }

            if depth < maxDepth {
                for child in AXHelper.childElements(of: element) {
                    queue.append((child, depth + 1))
                }
            }
        }
    }

    /// Cheap editability probe for the descendant search: a known editable role, an explicit
    /// editable flag, or either selection surface (native range or Chromium text markers). Cheaper
    /// than a full `candidateSnapshot`, so it is safe to run across the bounded BFS.
    private func looksEditable(_ element: AXUIElement) -> Bool {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        if AXHelper.isKnownEditableRole(role) {
            return true
        }
        if AXHelper.isKnownReadOnlyRole(role) {
            return false
        }
        let attributes = Set(AXHelper.attributeNames(on: element))
        if attributes.contains("AXSelectedTextMarkerRange")
            || attributes.contains(kAXSelectedTextRangeAttribute as String) {
            return true
        }
        if attributes.contains("AXEditable"),
            AXHelper.boolValue(for: "AXEditable" as CFString, on: element) == true {
            return true
        }
        return false
    }

    /// Extracts the AX properties Cotabby needs from one candidate element near the current focus.
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
        let editableHintScore = AXHelper.editabilityHintScore(
            role: role,
            explicitEditableFlag: explicitEditableFlag
        )
        let hasStrongEditabilitySignal = AXHelper.hasStrongEditabilitySignal(
            role: role,
            explicitEditableFlag: explicitEditableFlag
        )
        let isKnownReadOnlyRole = AXHelper.isKnownReadOnlyRole(role)
        let canBeEditableTarget = hasStrongEditabilitySignal && !isKnownReadOnlyRole
        let nativeSelection =
            canBeEditableTarget && supportedAttributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil

        // Chromium/WebKit contenteditables (Gmail body, Slack/Notion/Discord web, ClickUp chat)
        // expose selection only through the opaque AXTextMarker API, never kAXSelectedTextRange,
        // so they would otherwise fail the capability gate for a missing selection. Synthesize an
        // NSRange + caret-windowed text from the markers, but only when the native range is absent.
        let markerSelection =
            canBeEditableTarget && nativeSelection == nil
            ? AXHelper.synthesizeMarkerSelection(
                on: element, parameterizedAttributes: supportedParameterizedAttributes)
            : nil

        let nativeTextSelection = nativeSelection.flatMap {
            nativeTextWindow(
                on: element,
                selection: $0,
                supportedAttributes: supportedAttributes,
                supportedParameterizedAttributes: supportedParameterizedAttributes
            )
        }
        // Prefer the marker-windowed text when we synthesized one so `selection` (window-relative)
        // and `textValue` stay consistent; otherwise use a bounded native text window when the host
        // supports `AXStringForRange`, falling back to the full value for older/native controls.
        let textSelection = markerSelection.map {
            AXTextSelection(text: $0.text, selection: $0.selection)
        } ?? nativeTextSelection
        let selection = textSelection?.selection
        let selectionForGeometry = nativeSelection ?? markerSelection?.selection
        let textValue = textSelection?.text

        if let markerSelection {
            let textLength = (markerSelection.text as NSString).length
            let location = markerSelection.selection.location
            let length = markerSelection.selection.length
            CotabbyLogger.focus.trace(
                "CHROME-CONTENTEDITABLE synthesized selection loc=\(location) len=\(length) textLen=\(textLength)")
        }

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
        let caretResult = selectionForGeometry.flatMap {
            geometryResolver.resolveCaretRect(
                for: element,
                selection: $0,
                // A marker-synthesized selection's location is window-relative, not a document
                // offset, so NSRange-based BoundsForRange would resolve the wrong caret. Native
                // selections keep their document offset here, while `textSelection` below carries
                // the bounded-window offset for text-based geometry fallbacks.
                supportsBoundsForRange: markerSelection == nil
                    && supportedParameterizedAttributes.contains(
                        kAXBoundsForRangeParameterizedAttribute as String),
                supportsFrame: supportedAttributes.contains("AXFrame"),
                cocoaAnchorFrame: inputFrameRect,
                textValue: textValue,
                textSelection: selection
            )
        }
        let caretRect = caretResult?.rect
        let caretQuality = caretResult?.quality
        let isSecure = isSecureElement(element: element, role: role, subrole: subrole)
        let elementIdentifier = AXHelper.elementIdentifier(
            for: element, bundleIdentifier: bundleIdentifier)
        let resolverCandidate = FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: editableHintScore,
            hasStrongEditabilitySignal: hasStrongEditabilitySignal,
            isKnownReadOnlyRole: isKnownReadOnlyRole,
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
            isSecure: isSecure,
            resolverCandidate: resolverCandidate
        )
    }

    /// Reads the smallest native text window the host can provide around the current selection.
    ///
    /// `AXStringForRange` is the important fast path for large Chrome and WebKit fields: instead of
    /// pulling the whole `AXValue`, we ask for at most `focusedTextContextWindowUTF16` units before
    /// and after the caret. Apps that do not expose the parameterized string API still fall back to
    /// `AXValue`, preserving compatibility.
    private func nativeTextWindow(
        on element: AXUIElement,
        selection: NSRange,
        supportedAttributes: Set<String>,
        supportedParameterizedAttributes: Set<String>
    ) -> AXTextSelection? {
        func fullTextSelection() -> AXTextSelection? {
            guard supportedAttributes.contains(kAXValueAttribute as String),
                  let value = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            else {
                return nil
            }

            return AXTextSelection(text: value, selection: selection)
        }

        guard supportedParameterizedAttributes.contains(kAXStringForRangeParameterizedAttribute as String),
              supportedAttributes.contains(kAXNumberOfCharactersAttribute as String),
              let rawDocumentLength = AXHelper.intValue(
                  for: kAXNumberOfCharactersAttribute as CFString,
                  on: element
              ),
              rawDocumentLength >= 0
        else {
            return fullTextSelection()
        }

        let documentLength = rawDocumentLength
        let safeLocation = min(max(selection.location, 0), documentLength)
        let requestedEnd = selection.location > Int.max - selection.length
            ? Int.max
            : selection.location + selection.length
        let safeEnd = min(max(requestedEnd, safeLocation), documentLength)

        let beforeLength = min(safeLocation, Self.focusedTextContextWindowUTF16)
        let beforeStart = safeLocation - beforeLength
        let afterStart = safeEnd
        let afterLength = min(max(documentLength - afterStart, 0), Self.focusedTextContextWindowUTF16)

        guard let beforeText = AXHelper.parameterizedStringValue(
            for: kAXStringForRangeParameterizedAttribute as CFString,
            range: NSRange(location: beforeStart, length: beforeLength),
            on: element
        ) else {
            return fullTextSelection()
        }

        let selectedText: String
        if safeEnd > safeLocation {
            guard let nativeSelectedText = AXHelper.parameterizedStringValue(
                for: kAXStringForRangeParameterizedAttribute as CFString,
                range: NSRange(location: safeLocation, length: safeEnd - safeLocation),
                on: element
            ) else {
                return fullTextSelection()
            }
            selectedText = nativeSelectedText
        } else {
            selectedText = ""
        }

        let trailingText: String
        if afterLength > 0 {
            trailingText = AXHelper.parameterizedStringValue(
                for: kAXStringForRangeParameterizedAttribute as CFString,
                range: NSRange(location: afterStart, length: afterLength),
                on: element
            ) ?? ""
        } else {
            trailingText = ""
        }

        let text = beforeText + selectedText + trailingText
        return AXTextSelection(
            text: text,
            selection: NSRange(
                location: (beforeText as NSString).length,
                length: (selectedText as NSString).length
            )
        )
    }

    /// Detects secure inputs so Cotabby can intentionally refuse to operate in sensitive fields.
    private func isSecureElement(element: AXUIElement, role: String, subrole: String?) -> Bool {
        // Read the role description too: a native NSSecureTextField announces its sensitivity there
        // ("secure text field") rather than through AXDescription, so the previous role/desc/title-only
        // check missed it. SecureFieldDetector owns the (pure, testable) marker policy.
        SecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: AXHelper.stringValue(for: kAXRoleDescriptionAttribute as CFString, on: element),
            title: AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
            descriptionLabel: AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)
        )
    }
}

struct FocusCandidateResolution {
    let resolvedCandidate: AXFocusCandidate?
    let diagnosticCandidate: AXFocusCandidate?
    let resolution: FocusCapabilityResolution
}

private struct AXTextSelection {
    let text: String
    let selection: NSRange
}

/// AX data read from one candidate element near the current focus.
/// This keeps candidate search state local to the resolver instead of leaking it into the tracker.
struct AXFocusCandidate {
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
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
