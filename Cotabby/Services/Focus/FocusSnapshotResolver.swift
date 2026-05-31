import AppKit
import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Resolves the most usable editable candidate around the current AX focus and materializes a
/// stable `FocusSnapshot`. This keeps AX candidate search and snapshot assembly separate from the
/// polling shell in `FocusTracker`.
@MainActor
struct FocusSnapshotResolver {
    private let geometryResolver: AXTextGeometryResolver

    /// Throttle window for the deep caret BFS. ~100ms keeps the walk off the per-keystroke hot path
    /// in Chromium editors while staying short enough that caret lag during fast typing stays minor.
    private static let deepWalkThrottleInterval: TimeInterval = 0.1
    /// Maximum UTF-16 units kept on each side of the caret in focus snapshots.
    ///
    /// The prompt builder uses a much smaller suffix of `precedingText`, and autocomplete only needs
    /// a short trailing window for normalization. Keeping the focus snapshot bounded prevents a
    /// large editor buffer from flowing through equality checks, Combine publishes, and stale-result
    /// signatures on every AX refresh.
    private static let focusedTextContextWindowUTF16 = 4096

    /// Carries deep-walk throttle state across the value-typed resolver's non-mutating polls.
    private let deepWalkThrottle = DeepGeometryWalkThrottle()

    // MARK: - Debug AX tree dump
    /// Bundle identifier we automatically dump the AX tree for when `-cotabby-debug` is on.
    /// Chrome's contenteditable surfaces are the source of most caret-placement and host-AX-publish
    /// reports, so the dump exists primarily for triaging those — extend the gate (or replace the
    /// constant) once another bundle needs the same treatment.
    private static let dumpAXBundleIdentifier = "com.google.Chrome"
    /// Last focused-element identifier we wrote to disk. The dump only runs when this changes, so
    /// rapid focus events inside the same field don't repeatedly overwrite the file mid-inspection.
    private static var lastDumpedElementID: String?
    private static let dumpTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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

        // Auto-dump on debug builds only, and only when focus lands on the configured bundle
        // (currently Chrome). Debounced by element identity so rapid focus/value notifications
        // inside the same field don't overwrite the file mid-inspection.
        if CotabbyDebugOptions.isEnabled,
           bundleIdentifier == Self.dumpAXBundleIdentifier,
           Self.lastDumpedElementID != focusedElementIdentifier {
            Self.lastDumpedElementID = focusedElementIdentifier
            writeAXTreeDumpToDesktop(
                focusedElement: focusedElement,
                app: applicationName,
                bundle: bundleIdentifier
            )
        }

        // Chromium/Electron focus a wrapper several levels above the real editable, so for those
        // apps we additionally search descendants for the editable node.
        let deepDescendants = BrowserAppDetector.needsWebAccessibilityPriming(
            bundleIdentifier: bundleIdentifier)
        let candidateResolution = resolveCandidate(
            around: focusedElement,
            bundleIdentifier: bundleIdentifier,
            deepDescendants: deepDescendants
        )
        let resolution = candidateResolution.resolution
        let diagnosticCandidate = candidateResolution.diagnosticCandidate
        let inspection = FocusInspectionSnapshot(
            focusedElementIdentifier: focusedElementIdentifier,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole,
            resolvedElementIdentifier: diagnosticCandidate?.elementIdentifier,
            resolvedRole: diagnosticCandidate?.role,
            resolvedSubrole: diagnosticCandidate?.subrole,
            missingCapabilities: resolution.resolvedCandidate == nil
                ? resolution.missingCapabilities : []
        )

        guard let resolvedCandidate = candidateResolution.resolvedCandidate else {
            CotabbyLogger.focus.trace("Focus unsupported in \(applicationName): \(resolution.unsupportedReason)")
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
        // Native AppKit apps give exact caret rects on the input target itself. The deep BFS in
        // `resolveDeepGeometrySource` can recover a real `.exact` rect from a leaf AXStaticText
        // (via Branch 1.5 (TextMarker) on its zero-length selection range) when the focused input
        // only exposes weak geometry. Selection precedence and the search decision live in the
        // pure `CaretGeometrySelector`:
        //   1. primary `.exact`    (single API call, perfect — no walk needed)
        //   2. primary `.derived`  (trusted; the walk is skipped entirely for it)
        //   3. deep (any)          (only reached when primary is `.estimated`/unknown)
        //   4. primary (any, fallback)
        // The walk is skipped whenever primary geometry is already trustworthy (`.exact`/`.derived`),
        // and otherwise throttled to one BFS per `deepWalkThrottleInterval` while focus stays in the
        // same field, so the ~200-node walk does not run on every keystroke and pin a CPU core.
        // Within the window we reuse the previous deep result, which can trail the live caret by up
        // to one throttle interval of fast typing.
        let deepResult: CaretGeometryResult?
        if !CaretGeometrySelector.shouldSearchDeep(
            primaryRect: resolvedCandidate.caretRect,
            primaryQuality: resolvedCandidate.caretQuality
        ) {
            deepResult = nil
        } else {
            deepResult = deepWalkThrottle.result(
                focusChangeSequence: focusChangeSequence,
                interval: Self.deepWalkThrottleInterval
            ) {
                resolveDeepGeometrySource(
                    focusedElement: focusedElement,
                    resolvedElement: resolvedCandidate.element,
                    cocoaAnchorFrame: resolvedCandidate.inputFrameRect
                )
            }
        }

        guard let caret = CaretGeometrySelector.select(
            primaryRect: resolvedCandidate.caretRect,
            primaryQuality: resolvedCandidate.caretQuality,
            primaryObservedCharWidth: resolvedCandidate.observedCharWidth,
            deepResult: deepResult
        ) else {
            return FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: .unsupported("Caret bounds are unavailable."),
                context: nil,
                inspection: inspection
            )
        }
        let caretRect = caret.rect
        let caretSource = caret.source
        let caretQuality = caret.quality
        let observedCharWidth = caret.observedCharWidth

        let contextWindow = boundedContextWindow(text: value, selection: selection)
        let nsValue = contextWindow.text as NSString
        let safeSelectionLocation = min(contextWindow.selection.location, nsValue.length)
        let trailingStart = min(contextWindow.selection.location + contextWindow.selection.length, nsValue.length)
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
            selection: contextWindow.selection,
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

    /// Resolves candidate elements lazily and stops as soon as the first fully capable editable
    /// target is found.
    ///
    /// The old eager map built an `AXFocusCandidate` for every nearby Chromium node before asking
    /// `FocusCapabilityResolver` to pick the first supported one. In large web editors that meant
    /// reading text/selection/caret data from many wrapper and static-text nodes even after the real
    /// input target had already been discovered. This preserves the resolver's "first full
    /// capability wins" policy while avoiding unnecessary synchronous AX IPC.
    private func resolveCandidate(
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

    /// Returns a caret-adjacent text window and rewrites `selection` into that window's coordinate
    /// space. `NSRange` is UTF-16 based, so all slicing goes through `NSString`.
    private func boundedContextWindow(text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let nsText = text as NSString
        guard nsText.length > 0 else {
            return (text, NSRange(location: 0, length: 0))
        }

        let safeLocation = min(max(selection.location, 0), nsText.length)
        let requestedEnd = selection.location > Int.max - selection.length
            ? Int.max
            : selection.location + selection.length
        let safeEnd = min(max(requestedEnd, safeLocation), nsText.length)
        let beforeStart = max(0, safeLocation - Self.focusedTextContextWindowUTF16)
        let afterEnd = min(nsText.length, safeEnd + Self.focusedTextContextWindowUTF16)
        let rawWindow = NSRange(location: beforeStart, length: afterEnd - beforeStart)
        let composedWindow = nsText.rangeOfComposedCharacterSequences(for: rawWindow)
        let windowText = nsText.substring(with: composedWindow)

        let adjustedLocation = max(0, safeLocation - composedWindow.location)
        let adjustedLength = min(
            safeEnd - safeLocation,
            max(0, composedWindow.length - adjustedLocation)
        )

        return (
            windowText,
            NSRange(location: adjustedLocation, length: adjustedLength)
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

    // MARK: - Debug AX tree dump

    /// Renders the focused element plus its ancestors and children to plain text and overwrites
    /// `~/Desktop/cotabby-ax-dump.txt`. The file is overwritten so the user (or an AI debugger)
    /// always inspects the latest snapshot at a stable path. The dump is debounced to one write
    /// per focused-element identity change (see the call site).
    ///
    /// Writes are best-effort: a failed disk write is logged through `CotabbyLogger.focus` and
    /// does not propagate, since AX dumping is purely diagnostic.
    private func writeAXTreeDumpToDesktop(focusedElement: AXUIElement, app: String, bundle: String) {
        let timestamp = Self.dumpTimestampFormatter.string(from: Date())
        var out = "========== AX TREE DUMP ==========\n"
        out += "Timestamp: \(timestamp)\n"
        out += "App: \(app) (\(bundle))\n\n"

        out += "-- Focused + ancestors --\n"
        var ancestors: [AXUIElement] = [focusedElement]
        var currentElement = focusedElement
        for _ in 0..<3 {
            guard let parent = AXHelper.parentElement(of: currentElement) else { break }
            ancestors.append(parent)
            currentElement = parent
        }
        for (offset, element) in ancestors.enumerated().reversed() {
            let indent = String(repeating: "  ", count: ancestors.count - 1 - offset)
            out += describeNode(element, indent: indent)
        }

        out += "\n-- Children (depth 6) --\n"
        dumpChildrenRecursive(of: focusedElement, into: &out, indent: "", depth: 0)

        out += "========== END DUMP ==========\n"

        guard let desktopURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first else {
            CotabbyLogger.focus.error("AX dump skipped: no Desktop directory available")
            return
        }
        let targetURL = desktopURL.appendingPathComponent("cotabby-ax-dump.txt", isDirectory: false)
        do {
            try out.write(to: targetURL, atomically: true, encoding: .utf8)
            CotabbyLogger.focus.debug(
                "Wrote AX dump",
                metadata: [
                    "path": .string(targetURL.path),
                    "bundle": .string(bundle)
                ]
            )
        } catch {
            CotabbyLogger.focus.error(
                "Failed to write AX dump: \(error.localizedDescription)",
                metadata: ["path": .string(targetURL.path)]
            )
        }
    }

    private func dumpChildrenRecursive(
        of element: AXUIElement,
        into out: inout String,
        indent: String,
        depth: Int
    ) {
        guard depth < 6 else { return }
        let children = AXHelper.childElements(of: element)
        for (offset, child) in children.prefix(20).enumerated() {
            out += describeNode(child, indent: "\(indent)[\(offset)] ")
            dumpChildrenRecursive(of: child, into: &out, indent: indent + "  ", depth: depth + 1)
        }
        if children.count > 20 {
            out += "\(indent)  ...+\(children.count - 20) more\n"
        }
    }

    private func describeNode(_ element: AXUIElement, indent: String) -> String {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))

        var summary = "\(indent)\(role)"
        if let subrole { summary += " (\(subrole))" }
        summary += "\n"

        if let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element) {
            let cocoa = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            summary += "\(indent)  frame(AX): \(fmt(frame))  frame(cocoa): \(fmt(cocoa))\n"
        }

        if attributes.contains(kAXValueAttribute as String),
            let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element) {
            let previewText = text.count > 80 ? String(text.prefix(80)) + "…" : text
            summary += "\(indent)  value: " +
                "\"\(previewText.replacingOccurrences(of: "\n", with: "\\n"))\" " +
                "(len=\(text.count))\n"
        }

        if let range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element) {
            summary += "\(indent)  selection: loc=\(range.location) len=\(range.length)\n"

            if parameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String) {
                let boundsRect = AXHelper.parameterizedRectValue(
                    for: kAXBoundsForRangeParameterizedAttribute as CFString,
                    range: NSRange(location: range.location, length: 0),
                    on: element
                )
                if let boundsRect, !boundsRect.isEmpty {
                    summary += "\(indent)  BoundsForRange(loc,0): \(fmt(boundsRect))\n"
                } else {
                    summary += "\(indent)  BoundsForRange(loc,0): FAILED\n"
                }
            }
        }

        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            summary += "\(indent)  TextMarkerCaret: \(fmt(markerRect))\n"
        }

        if let isEditable = AXHelper.boolValue(for: "AXEditable" as CFString, on: element) {
            summary += "\(indent)  editable: \(isEditable)\n"
        }

        let childCount = AXHelper.childElements(of: element).count
        if childCount > 0 { summary += "\(indent)  children: \(childCount)\n" }

        return summary
    }

    private func fmt(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f×%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

/// Throttles the deep-tree caret BFS so it runs at most once per `interval` while focus stays on one
/// field. `findDeepGeometrySource` walks up to ~200 AX nodes with several synchronous IPC round-trips
/// each; in Chromium editors (e.g. Gmail) the focused element reports only `.derived` primary
/// geometry, so the walk fired on every keystroke and pinned a CPU core. Reusing the prior deep
/// result inside the window keeps caret-source selection identical while collapsing the
/// per-keystroke AX traffic.
///
/// Keyed on `FocusTracker`'s `focusChangeSequence` rather than the AX element: Chrome recycles AX
/// node handles, so an element-identity key would miss on nearly every poll and defeat the throttle,
/// whereas the sequence is derived from the field frame and stays stable across keystrokes in one
/// field. A changed sequence is a real field switch and forces an immediate fresh walk.
///
/// A reference type so it can carry state across the value-typed resolver's non-mutating
/// `resolveSnapshot`. The resolver is constructed once and retained by `FocusTracker`.
@MainActor
final class DeepGeometryWalkThrottle {
    private var lastSequence: UInt64?
    private var lastWalkAt: Date?
    private var cachedResult: CaretGeometryResult?

    /// Runs `walk` only when the throttle window has elapsed or the focused field changed; otherwise
    /// returns the previous deep result. `now` is injectable for tests.
    func result(
        focusChangeSequence: UInt64,
        interval: TimeInterval,
        now: Date = Date(),
        walk: () -> CaretGeometryResult?
    ) -> CaretGeometryResult? {
        if focusChangeSequence == lastSequence,
            let lastWalkAt,
            now.timeIntervalSince(lastWalkAt) < interval {
            return cachedResult
        }

        let result = walk()
        lastSequence = focusChangeSequence
        lastWalkAt = now
        cachedResult = result
        return result
    }
}

private struct FocusCandidateResolution {
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
    let isSecure: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
