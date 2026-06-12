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
    ///
    /// Internal (not private) so the caret layout repair can detect "the captured prefix filled the
    /// window and may not start at the document start" — laying out a mid-document prefix would
    /// produce meaningless wrap/Y geometry, so that case must be rejected.
    static let focusedTextContextWindowUTF16 = 4096

    /// Carries deep-walk throttle state across the value-typed resolver's non-mutating polls.
    private let deepWalkThrottle = DeepGeometryWalkThrottle()

    /// Same lifetime trick for the Branch 2.5 static-text-run walk: collected run frames are
    /// reused across polls of one field instead of re-walking up to ~300 nodes per tick.
    private let staticRunWalkThrottle = StaticTextRunWalkThrottle()

    /// Session-scoped caches for AX reads that are invariant while focus stays in one field.
    /// Secure-field verdicts gate whether Cotabby operates at all, so they are scoped to the
    /// focus-change sequence rather than raw element identity, which CFHash can recycle across
    /// fields (see `FocusSessionScopedCache`).
    private let secureFieldVerdictCache = FocusSessionScopedCache<Bool>()
    private let terminalDetectionCache = FocusSessionScopedCache<Bool>()

    /// Caches the resolved field font/color per focused element so the attributed-string AX read
    /// happens once per field rather than on every poll. Reference type for the same reason as
    /// `deepWalkThrottle`: it carries state across the value-typed resolver's non-mutating polls.
    private let fieldStyleCache = FieldStyleCache()

    /// Caches the per-field surface metadata (window title, placeholder, URL) the same way; see
    /// `SurfaceContextCache` for why the value is frozen for the whole field session.
    private let surfaceContextCache = SurfaceContextCache()

    init(geometryResolver: AXTextGeometryResolver? = nil) {
        self.geometryResolver = geometryResolver ?? AXTextGeometryResolver()
    }

    /// Drops the cached static-text-run walk so the next capture pays a fresh one. Called through
    /// the focus provider after Cotabby's own synthetic insert: the cached run texts predate the
    /// inserted chunk, and mapping the published caret against them lands a word left of the
    /// truth (the accept-time jitter on child-run hosts).
    func invalidateStaticRunWalkCache() {
        staticRunWalkThrottle.invalidate()
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

        // Auto-dump the AX tree on debug builds for the configured bundle (currently Chrome),
        // debounced by focused-element identity. Lives in AXTreeDumpWriter so this resolver stays
        // focused on snapshot assembly rather than diagnostic disk I/O.
        AXTreeDumpWriter.dumpIfEnabled(
            focusedElement: focusedElement,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            focusedElementIdentifier: focusedElementIdentifier
        )

        // Chromium/Electron focus a wrapper several levels above the real editable, so for those
        // apps we additionally search descendants for the editable node.
        let deepDescendants = BrowserAppDetector.needsWebAccessibilityPriming(
            bundleIdentifier: bundleIdentifier)
        let candidateResolution = resolveCandidate(
            around: FocusedElementReading(
                element: focusedElement,
                role: focusedRole,
                subrole: focusedSubrole
            ),
            bundleIdentifier: bundleIdentifier,
            deepDescendants: deepDescendants,
            focusChangeSequence: focusChangeSequence
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
            primaryObservedContentEdges: resolvedCandidate.observedContentEdges,
            primarySourceDetail: resolvedCandidate.caretSourceDetail,
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
        let observedContentEdges = caret.observedContentEdges

        let contextWindow = boundedContextWindow(text: value, selection: selection)
        let nsValue = contextWindow.text as NSString
        let safeSelectionLocation = min(contextWindow.selection.location, nsValue.length)
        let trailingStart = min(contextWindow.selection.location + contextWindow.selection.length, nsValue.length)
        // Surface metadata (window title, field placeholder, page URL), captured once per field
        // session and frozen for its lifetime: re-reading per poll would add cross-process AX
        // round-trips to the hot path, and a retitling window mid-typing would change the prompt
        // bytes ahead of the prefix and break llama KV prefix reuse. The URL is read for browsers
        // (surface conditioning) or whenever per-site disable wants it; navigation recreates the
        // focused web element, so a stale URL cannot outlive its page. Secure fields are never
        // probed.
        let capturedSurface: CapturedSurfaceContext
        if resolvedCandidate.isSecure {
            capturedSurface = .empty
        } else {
            let surfaceKey =
                "\(application.processIdentifier):\(resolvedCandidate.elementIdentifier):\(focusChangeSequence)"
            capturedSurface = surfaceContextCache.capture(forKey: surfaceKey) {
                let wantsURL = PerDomainDisableSettings.isEnabled()
                    || BrowserAppDetector.isBrowser(bundleIdentifier: bundleIdentifier)
                return CapturedSurfaceContext(
                    windowTitle: AXHelper.windowTitle(near: focusedElement),
                    fieldPlaceholder: AXHelper.stringValue(
                        for: kAXPlaceholderValueAttribute as CFString,
                        on: resolvedCandidate.element
                    ),
                    urlString: wantsURL ? AXHelper.webURL(near: focusedElement) : nil
                )
            }
        }
        let focusedURLString = capturedSurface.urlString
        // Resolve the host field's own font/color so ghost text can match it. Cached by element
        // identity (this is a synchronous AX read and the resolver runs on the focus poll), and
        // skipped for secure fields, which are never styled or assisted.
        let resolvedFieldStyle: ResolvedFieldStyle?
        if resolvedCandidate.isSecure {
            resolvedFieldStyle = nil
        } else {
            let styleKey = "\(application.processIdentifier):\(resolvedCandidate.elementIdentifier)"
            resolvedFieldStyle = fieldStyleCache.style(forKey: styleKey) {
                AXHelper.resolveFieldStyle(
                    for: resolvedCandidate.element,
                    caretLocation: selection.location,
                    textLength: value.utf16.count
                )
            }
        }
        // Recognize an xterm.js integrated terminal (VS Code / Cursor / web terminal) from the
        // focused element's DOM classes. The terminal, code editor, and Copilot chat all live in one
        // process, so this surface-level signal is the only way to suppress ghost text in the
        // terminal while leaving the editor and chat working. Read on the focused element because
        // that is exactly where xterm puts the caret (`xterm-helper-textarea`). Computed here — only
        // once a real editable field has resolved — so idle/non-editable focus polls don't pay for an
        // extra AXDOMClassList round-trip; native apps don't vend the attribute anyway. Cached per
        // focus session because the class list on one focused element cannot change without a field
        // switch bumping the sequence, which previously cost one round-trip on every poll tick.
        let isIntegratedTerminal = terminalDetectionCache.value(
            forKey: focusedElementIdentifier,
            focusChangeSequence: focusChangeSequence
        ) {
            TerminalAppDetector.isIntegratedTerminal(
                domClassList: AXHelper.stringArrayValue(
                    for: "AXDOMClassList" as CFString, on: focusedElement) ?? []
            )
        }
        // Web-vs-native classification for the caret-geometry trust policy. The DOM-attribute
        // signal was computed in `candidateSnapshot` from the attribute list it already fetched,
        // so this adds no AX round-trip to the focus poll.
        let isWebContentField = WebContentFieldDetector.isWebContentField(
            bundleIdentifier: bundleIdentifier,
            vendsDOMAttributes: resolvedCandidate.vendsDOMAttributes
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
            observedContentEdges: observedContentEdges,
            precedingText: nsValue.substring(to: safeSelectionLocation),
            trailingText: nsValue.substring(from: trailingStart),
            selection: contextWindow.selection,
            isSecure: resolvedCandidate.isSecure,
            isIntegratedTerminal: isIntegratedTerminal,
            isWebContentField: isWebContentField,
            focusChangeSequence: focusChangeSequence,
            focusedURLString: focusedURLString,
            resolvedFieldStyle: resolvedFieldStyle,
            windowTitle: capturedSurface.windowTitle,
            fieldPlaceholder: capturedSurface.fieldPlaceholder
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
    ///
    /// Candidate enumeration is staged the same way: the bounded descendant BFS used for Chromium
    /// wrappers costs hundreds of additional AX round trips per pass, and a shallow candidate
    /// (focused node, ancestors, their children) wins in the common case — including Chromium
    /// hosts that focus the editable directly — so the BFS runs only when no shallow candidate
    /// resolves with full capabilities. Evaluation order is unchanged: shallow candidates always
    /// preceded BFS appends, so any shallow winner made the BFS results unreachable anyway.
    private func resolveCandidate(
        around focusedReading: FocusedElementReading,
        bundleIdentifier: String,
        deepDescendants: Bool,
        focusChangeSequence: UInt64
    ) -> FocusCandidateResolution {
        var bestPartial: (candidate: AXFocusCandidate, evaluation: FocusCapabilityCandidateEvaluation)?
        var inspectedCount = 0

        func winner(in elements: [AXUIElement]) -> FocusCandidateResolution? {
            for element in elements {
                inspectedCount += 1
                let candidate = candidateSnapshot(
                    for: element,
                    bundleIdentifier: bundleIdentifier,
                    focusChangeSequence: focusChangeSequence,
                    focusedReading: focusedReading
                )
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

            return nil
        }

        var seen = Set<String>()
        let shallow = shallowCandidateElements(around: focusedReading.element, seen: &seen)
        if let resolved = winner(in: shallow.ordered) {
            return resolved
        }

        if deepDescendants {
            var deepCandidates: [AXUIElement] = []
            appendEditableDescendants(of: [focusedReading.element] + shallow.ancestors) { element in
                guard let element else {
                    return
                }
                guard seen.insert(AXHelper.elementIdentity(for: element)).inserted else {
                    return
                }
                deepCandidates.append(element)
            }
            if let resolved = winner(in: deepCandidates) {
                return resolved
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

    /// Enumerates the cheap nearby candidates: the focused node, up to two ancestors, and their
    /// children. The Chromium descendant BFS is intentionally not part of this list — see
    /// `resolveCandidate` for the staging rationale (Chromium reports focus on a wrapper above the
    /// editable, AXWebArea → AXGroup → … → AXTextField, so the BFS exists as the fallback for the
    /// cases where this shallow neighborhood misses the real target).
    private func shallowCandidateElements(
        around focusedElement: AXUIElement, seen: inout Set<String>
    ) -> (ordered: [AXUIElement], ancestors: [AXUIElement]) {
        var ordered: [AXUIElement] = []

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

        return (ordered, ancestors)
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
        case .derived, .layoutEstimated:
            // `.layoutEstimated` is unreachable here: it exists only as a presentation-time
            // upgrade applied to overlay geometry, never as a resolver output. Scored alongside
            // `.derived` purely to keep this switch exhaustive.
            return 1
        case .estimated:
            return 0
        }
    }

    /// Extracts the AX properties Cotabby needs from one candidate element near the current focus.
    private func candidateSnapshot(
        for element: AXUIElement,
        bundleIdentifier: String,
        focusChangeSequence: UInt64,
        focusedReading: FocusedElementReading
    ) -> AXFocusCandidate {
        // `resolveSnapshot` already read the focused element's role pair for diagnostics, and the
        // focused element is the winning candidate in the common case; re-reading would repeat two
        // AX round trips on every poll tick. `CFEqual` is a local comparison, not an IPC.
        let role: String
        let subrole: String?
        if CFEqual(element, focusedReading.element) {
            role = focusedReading.role
            subrole = focusedReading.subrole
        } else {
            role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
            subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        }
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
                textSelection: selection,
                // The run-walk throttle slot is shared across calls, so it is restricted to the
                // focused element: that is the per-tick steady-state caller, and scoping prevents
                // one slot from serving run frames collected under a different root element.
                staticRunThrottle: CFEqual(element, focusedReading.element)
                    ? staticRunWalkThrottle
                    : nil,
                focusChangeSequence: focusChangeSequence
            )
        }
        let caretRect = caretResult?.rect
        let caretQuality = caretResult?.quality
        // Recorded from the already-fetched attribute list (no extra AX call) so snapshot
        // assembly can classify the field as web-rendered without touching the element again.
        let vendsDOMAttributes = WebContentFieldDetector.vendsDOMAttributes(supportedAttributes)
        let elementIdentifier = AXHelper.elementIdentifier(
            for: element, bundleIdentifier: bundleIdentifier)
        // Secure-ness is invariant for an element's lifetime, and the three marker probes behind
        // it (role description, title, description) are separate AX round trips otherwise paid on
        // every poll tick. Session scoping keeps recycled element identities from ever serving a
        // stale verdict to a different field.
        let isSecure = secureFieldVerdictCache.value(
            forKey: elementIdentifier,
            focusChangeSequence: focusChangeSequence
        ) {
            isSecureElement(element: element, role: role, subrole: subrole)
        }
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
            observedContentEdges: caretResult?.observedContentEdges,
            caretSourceDetail: caretResult?.sourceDetail,
            inputFrameRect: inputFrameRect,
            isSecure: isSecure,
            vendsDOMAttributes: vendsDOMAttributes,
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

private struct FocusCandidateResolution {
    let resolvedCandidate: AXFocusCandidate?
    let diagnosticCandidate: AXFocusCandidate?
    let resolution: FocusCapabilityResolution
}

/// The focused element together with its already-read role pair, so candidate snapshotting can
/// reuse the reads `resolveSnapshot` performed for diagnostics instead of repeating the IPC.
private struct FocusedElementReading {
    let element: AXUIElement
    let role: String
    let subrole: String?
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
    let observedContentEdges: ObservedContentEdges?
    let caretSourceDetail: String?
    let inputFrameRect: CGRect?
    let isSecure: Bool
    /// Whether the element advertises DOM-reflection attributes, marking it as web-engine
    /// content (see `WebContentFieldDetector`).
    let vendsDOMAttributes: Bool
    let resolverCandidate: FocusCapabilityCandidate
}
