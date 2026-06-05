import AppKit
import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Materializes a stable `FocusSnapshot` from the current AX focus. It delegates candidate search
/// and per-element AX reads to `FocusCandidateResolver`, resolves caret geometry (primary plus the
/// throttled deep walk) via `CaretGeometryResolver` / `CaretGeometrySelector`, and assembles the
/// snapshot. This keeps snapshot assembly separate from both AX candidate search and the polling
/// shell in `FocusTracker`.
@MainActor
struct FocusSnapshotResolver {
    private let candidateResolver: FocusCandidateResolver
    private let geometryResolver: CaretGeometryResolver

    /// Throttle window for the deep caret BFS. ~100ms keeps the walk off the per-keystroke hot path
    /// in Chromium editors while staying short enough that caret lag during fast typing stays minor.
    private static let deepWalkThrottleInterval: TimeInterval = 0.1

    init(geometryResolver: CaretGeometryResolver? = nil) {
        let resolver = geometryResolver ?? CaretGeometryResolver()
        self.geometryResolver = resolver
        self.candidateResolver = FocusCandidateResolver(geometryResolver: resolver)
    }

    /// Resolves the best editable candidate around the focused AX node and materializes a focus snapshot.
    ///
    /// `focusChangeSequence` is a monotonic counter owned by `FocusTracker`. The resolver threads
    /// it into the resulting `FocusedInputSnapshot` so downstream consumers can detect field
    /// switches even when `CFHash`-based `elementIdentifier` collides across recycled AX nodes.
    ///
    /// `deepWalkThrottle` is also owned by `FocusTracker` (a stable lifetime) and passed in so this
    /// value-typed resolver carries no hidden mutable reference state.
    func resolveSnapshot(
        focusedElement: AXUIElement,
        application: NSRunningApplication,
        focusChangeSequence: UInt64 = 0,
        deepWalkThrottle: DeepGeometryWalkThrottle
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
        let candidateResolution = candidateResolver.resolve(
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
                geometryResolver.resolveDeepGeometrySource(
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
        // Per-site disable: read the page URL only when the feature is enabled, so the default
        // focus-capture path performs no extra Accessibility round-trips. The read is fail-safe (nil on
        // any miss), so the worst case is the per-site gate staying inert.
        let focusedURLString = PerDomainDisableSettings.isEnabled()
            ? AXHelper.webURL(near: focusedElement)
            : nil
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
            focusChangeSequence: focusChangeSequence,
            focusedURLString: focusedURLString
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
        let beforeStart = max(0, safeLocation - FocusCandidateResolver.focusedTextContextWindowUTF16)
        let afterEnd = min(nsText.length, safeEnd + FocusCandidateResolver.focusedTextContextWindowUTF16)
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
}
