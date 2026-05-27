import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// File overview:
/// Resolves caret and input-frame geometry from AX elements. This file centralizes the fragile
/// browser/native heuristics used to place overlays, caret badges, and screenshot crops correctly.
///
/// Separating geometry heuristics from `FocusTracker` makes compatibility bugs easier to reason
/// about: if the wrong element is selected, the resolver layer is at fault; if the right element
/// is selected but the caret anchor is wrong, this geometry layer is the place to debug.

/// Pairs a caret rect with the method that produced it, so callers can decide
/// whether to trust the position or search for a better geometry source.
struct CaretGeometryResult {
    let rect: CGRect
    let quality: CaretGeometryQuality
    /// Observed average character width in Cocoa points, derived from real AX child frame
    /// measurements. Used by caret prediction after tab insertion so the overlay shift matches
    /// the actual font instead of guessing with a system font fallback. Nil when no child
    /// frame data was available (e.g. BoundsForRange worked directly).
    let observedCharWidth: CGFloat?

    init(rect: CGRect, quality: CaretGeometryQuality, observedCharWidth: CGFloat? = nil) {
        self.rect = rect
        self.quality = quality
        self.observedCharWidth = observedCharWidth
    }
}

@MainActor
struct AXTextGeometryResolver {
    /// Remembers the text-run leaves of the focused field so per-keystroke caret resolution can
    /// re-read them instead of re-walking the tree. Nil disables caching (tests, non-focus callers).
    ///
    /// Exposed (not private) so `FocusSnapshotResolver` can adopt this exact instance for its own
    /// deep-walk fast path. If the two types held separate caches, an injected resolver would
    /// silently lose run-walk caching while deep-walk caching kept working.
    let cache: CaretGeometrySourceCache?

    init(cache: CaretGeometrySourceCache? = nil) {
        self.cache = cache
    }

    /// Resolves the full input frame for workflows that need the whole field bounds, such as
    /// screenshot cropping and field-level diagnostics. This stays separate from caret resolution
    /// because not every consumer wants the same geometry contract.
    func resolveInputFrameRect(for element: AXUIElement) -> CGRect? {
        guard let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element),
            !frame.isEmpty
        else {
            return nil
        }

        return AXHelper.cocoaRect(fromAccessibilityRect: frame)
    }

    /// Finds the best caret anchor available, preferring bounds-for-range and falling back to element frame.
    /// `cocoaAnchorFrame` is the element's AXFrame already converted to Cocoa coordinates — it serves
    /// as the ground-truth reference for detecting whether text-range rects need pixel-to-point scaling.
    func resolveCaretRect(
        for element: AXUIElement,
        selection: NSRange,
        supportsBoundsForRange: Bool,
        supportsFrame: Bool,
        cocoaAnchorFrame: CGRect?,
        textValue: String? = nil,
        focusChangeSequence: UInt64? = nil
    ) -> CaretGeometryResult? {
        // Branch 1: Zero-length BoundsForRange at the caret position — ideal case.
        // Gated on `supportsBoundsForRange` because the API is a synchronous cross-process
        // call into the focused app's AX implementation. In Chrome that's a round-trip into
        // the renderer, and the deep-tree walker can touch many leaves per focus poll; calling
        // BoundsForRange on nodes that don't advertise support stalled the main thread badly
        // enough to freeze typing. The `rectIsNearAnchor` validator stays as a correctness
        // guard for supporters that return rects belonging to an unrelated range.
        if supportsBoundsForRange,
            let rect = AXHelper.parameterizedRectValue(
                for: kAXBoundsForRangeParameterizedAttribute as CFString,
                range: NSRange(location: selection.location, length: 0),
                on: element
            ), !rect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rect,
                anchorFrame: cocoaAnchorFrame
            )
            if rectIsNearAnchor(cocoaRect, anchor: cocoaAnchorFrame) {
                return CaretGeometryResult(
                    rect: normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect),
                    quality: .exact
                )
            }
        }

        // Branch 1.5: Chromium / WebKit AXTextMarker fallback.
        // Apps like Discord/Chrome fail NSRange queries but return a correct bounding box
        // when we ask for the caret via their internal AXTextMarkerRange objects.
        if let markerRect = AXHelper.textMarkerCaretRect(on: element), !markerRect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: markerRect,
                anchorFrame: cocoaAnchorFrame
            )
            return CaretGeometryResult(
                rect: normalizedCaretRect(fromZeroLengthRangeRect: cocoaRect),
                quality: .exact
            )
        }

        // Branch 1.6: Ancestor-owned AXTextMarker selection.
        // Chromium contenteditable fields can focus a nested text entry node while the page-wide
        // text marker space is owned by an ancestor such as AXWebArea. Walking upward finds that
        // owner without depending on it appearing in the shallow candidate list.
        if let ancestorMarkerRect = resolveCaretFromAncestorTextMarkerRange(
            of: element,
            cocoaAnchorFrame: cocoaAnchorFrame
        ) {
            return CaretGeometryResult(
                rect: normalizedCaretRect(fromZeroLengthRangeRect: ancestorMarkerRect),
                quality: .exact
            )
        }

        // Branch 2: BoundsForRange on the character before the caret, then shift to its trailing edge.
        // Same gate and anchor validation as Branch 1.
        if supportsBoundsForRange,
            selection.location > 0,
            let rect = AXHelper.parameterizedRectValue(
                for: kAXBoundsForRangeParameterizedAttribute as CFString,
                range: NSRange(location: selection.location - 1, length: 1),
                on: element
            ), !rect.isEmpty {
            let cocoaRect = AXHelper.validatedCocoaTextRect(
                fromAccessibilityRect: rect,
                anchorFrame: cocoaAnchorFrame
            )
            if rectIsNearAnchor(cocoaRect, anchor: cocoaAnchorFrame),
                !looksLikeOversizedSingleCharacterRange(cocoaRect, anchor: cocoaAnchorFrame),
                !looksLikeStaleLineStartRange(
                    cocoaRect,
                    anchor: cocoaAnchorFrame,
                    text: textValue,
                    selection: selection
                ),
                !looksLikeMultilineRangeUnion(cocoaRect, in: element) {
                return CaretGeometryResult(
                    rect: CGRect(
                        x: cocoaRect.maxX, y: cocoaRect.minY, width: 2, height: cocoaRect.height),
                    quality: .derived
                )
            }
        }

        // Branch 2.5: Child text-run proportional estimation.
        // Gmail, Outlook, and other Chromium editors fail BoundsForRange entirely but expose
        // AXStaticText children with tight per-text-run AXFrames. Walk those children to find
        // which one contains the caret, then estimate position proportionally within its frame.
        if let parentText = textValue, !parentText.isEmpty {
            if let result = resolveCaretFromChildTextRuns(
                element: element,
                parentSelection: selection,
                parentText: parentText,
                focusChangeSequence: focusChangeSequence
            ) {
                return result
            }
        }

        // Branch 3: AXFrame fallback — no text-range data available, estimate from element bounds.
        if supportsFrame,
            let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element), !frame.isEmpty {
            let cocoaRect = AXHelper.cocoaRect(fromAccessibilityRect: frame)
            if cocoaRect.width > 10, let text = textValue {
                let estimatedX = conservativeEstimatedCaretX(
                    in: cocoaRect,
                    text: text,
                    selection: selection
                )
                let clampedX = min(estimatedX, cocoaRect.maxX)
                return CaretGeometryResult(
                    rect: CGRect(
                        x: clampedX, y: cocoaRect.minY, width: 2, height: cocoaRect.height),
                    quality: .estimated
                )
            }
            return CaretGeometryResult(rect: cocoaRect, quality: .estimated)
        }

        return nil
    }

    /// Best-effort caret estimate when AX exposes only the full field frame.
    ///
    /// This path is intentionally conservative. The previous `prefix.count * 8` heuristic drifted
    /// farther right as more text was accepted, especially in apps whose real font is narrower
    /// than the hard-coded guess or whose prefix spans multiple lines. We now:
    /// 1. Measure only the current line fragment after the last newline.
    /// 2. Use a system-font width estimate as a fallback proxy for rendered width.
    /// 3. Apply a modest upward bias because this fallback routinely underestimates larger editors
    ///    that only expose `AXFrame`, then keep a loose per-character ceiling as a guardrail.
    private func conservativeEstimatedCaretX(
        in cocoaRect: CGRect,
        text: String,
        selection: NSRange
    ) -> CGFloat {
        let nsText = text as NSString
        let safeLocation = min(selection.location, nsText.length)
        let prefix = nsText.substring(to: safeLocation)
        let currentLinePrefix = prefix.components(separatedBy: .newlines).last ?? prefix
        let lineNSString = currentLinePrefix as NSString

        let estimatedWidthBias: CGFloat = 1.1
        let measuredWidth =
            lineNSString.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 15)
            ]).width * estimatedWidthBias
        let perCharacterCeiling: CGFloat = 13.3 * estimatedWidthBias
        let estimatedWidth = min(
            measuredWidth,
            CGFloat(lineNSString.length) * perCharacterCeiling
        )

        return cocoaRect.minX + estimatedWidth
    }

    private func resolveCaretFromAncestorTextMarkerRange(
        of element: AXUIElement,
        cocoaAnchorFrame: CGRect?
    ) -> CGRect? {
        let maxAncestorDepth = 16
        var currentElement = element
        var seen = Set<String>()

        for _ in 0..<maxAncestorDepth {
            guard let parent = AXHelper.parentElement(of: currentElement) else {
                return nil
            }

            let identity = AXHelper.elementIdentity(for: parent)
            guard seen.insert(identity).inserted else {
                return nil
            }

            if let markerRect = AXHelper.textMarkerCaretRect(on: parent), !markerRect.isEmpty {
                let cocoaRect = AXHelper.validatedCocoaTextRect(
                    fromAccessibilityRect: markerRect,
                    anchorFrame: cocoaAnchorFrame
                )
                if isPlausibleTextRect(cocoaRect, near: cocoaAnchorFrame) {
                    return cocoaRect
                }
            }

            currentElement = parent
        }

        return nil
    }

    private func isPlausibleTextRect(_ rect: CGRect, near anchorFrame: CGRect?) -> Bool {
        guard !rect.isEmpty else {
            return false
        }

        guard let anchorFrame, !anchorFrame.isEmpty else {
            return true
        }

        let tolerance: CGFloat = 80
        return anchorFrame
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// Walks AXStaticText children of a text container to find the one containing the caret,
    /// then estimates caret position proportionally within that child's AXFrame. This is the
    /// primary caret resolution path for Gmail, Outlook, and other Chromium editors where
    /// BoundsForRange fails but per-text-run child frames are precise.
    private func resolveCaretFromChildTextRuns(
        element: AXUIElement,
        parentSelection: NSRange,
        parentText: String,
        focusChangeSequence: UInt64?
    ) -> CaretGeometryResult? {
        let parentTextLength = (parentText as NSString).length
        guard parentSelection.location <= parentTextLength else {
            return nil
        }

        // Per-line runs omit the line breaks the field value keeps, so a caret near the end of a
        // multi-line message sits past the summed run length by the number of breaks above it. Size
        // the past-all-runs tolerance to that glue so the fallback still anchors to the last run
        // instead of collapsing to the whole-field estimate, while a larger overshoot still rejects
        // an incomplete or label-polluted run list.
        let caretLocation = min(parentSelection.location, parentTextLength)
        let newlinesBeforeCaret = (parentText as NSString).substring(to: caretLocation)
            .unicodeScalars
            .reduce(into: 0) { count, scalar in
                if CharacterSet.newlines.contains(scalar) { count += 1 }
            }
        let missingTextTolerance = max(2, newlinesBeforeCaret)

        let fieldKey: CaretGeometrySourceCache.FieldKey?
        if let focusChangeSequence, cache != nil {
            fieldKey = CaretGeometrySourceCache.FieldKey(
                containerIdentifier: AXHelper.elementIdentity(for: element),
                focusChangeSequence: focusChangeSequence
            )
        } else {
            fieldKey = nil
        }

        // Fast path: re-read the cached line leaves instead of re-walking the tree. A successful
        // caret map means the field's line structure is intact — including after the caret jumped
        // lines, since the offset simply maps to a different cached run. A nil map (e.g. a line the
        // cache predates) falls through to a fresh walk that refreshes the cache.
        if let fieldKey, let cache,
            let cachedElements = cache.textRunElements(for: fieldKey),
            let runs = textRuns(fromElements: cachedElements), !runs.isEmpty,
            let result = caretResult(fromRuns: runs, caretOffset: parentSelection.location) {
            return result
        }

        // Slow path: discover the leaves with a bounded walk, then map. The resolved field's leaves
        // are cached once after candidate selection by `cacheTextRunSources` — deliberately not here
        // — so a non-winning candidate probed on the same poll cannot evict the focused field's entry
        // and force a re-walk every keystroke.
        let elements = collectStaticTextElements(from: element)
        guard !elements.isEmpty,
            let runs = textRuns(fromElements: elements), !runs.isEmpty else {
            return nil
        }
        return caretResult(fromRuns: runs, caretOffset: parentSelection.location)
    }

    /// Populates the text-run cache for the resolved field once candidate selection is done.
    ///
    /// `FocusSnapshotResolver` probes every candidate with the run cache read-only: each candidate
    /// has a distinct cache identity and the cache holds a single field, so letting every probe write
    /// would let a non-winning candidate evict the focused field's leaves on the same poll and force
    /// a re-walk every keystroke. The resolver instead calls this once for the winner. Already-warm
    /// fields are a no-op; the walk runs only when the entry is cold (first poll on a field) or a
    /// line change moved the caret off the cached leaves.
    func cacheTextRunSources(for element: AXUIElement, focusChangeSequence: UInt64) {
        guard let cache else {
            return
        }

        let fieldKey = CaretGeometrySourceCache.FieldKey(
            containerIdentifier: AXHelper.elementIdentity(for: element),
            focusChangeSequence: focusChangeSequence
        )
        guard cache.textRunElements(for: fieldKey) == nil else {
            return
        }

        let elements = collectStaticTextElements(from: element)
        guard !elements.isEmpty,
            let runs = textRuns(fromElements: elements), !runs.isEmpty else {
            return
        }
        cache.store(textRunElements: elements, for: fieldKey)
    }

    /// Maps a caret offset onto ordered text runs: walk cumulative text length to find the
    /// containing run, then interpolate proportionally inside its frame. Returns nil when the offset
    /// overshoots the runs by more than a small tolerance — the signal that the run list is stale or
    /// incomplete, so the caller should re-walk rather than anchor the overlay to an unrelated tail.
    private func caretResult(
        fromRuns textRuns: [(text: String, frame: CGRect)],
        caretOffset: Int
    ) -> CaretGeometryResult? {
        // Average character width measured directly from the child frames — the actual rendered
        // font, not a guess. Aggregated across runs so one short run doesn't skew it.
        var totalChars = 0
        var totalWidth: CGFloat = 0
        for run in textRuns {
            totalChars += (run.text as NSString).length
            totalWidth += run.frame.width
        }
        let charWidth: CGFloat? = totalChars > 0 ? totalWidth / CGFloat(totalChars) : nil

        // AX selections use UTF-16 offsets, so match on NSString length.
        var cumulative = 0
        for run in textRuns {
            let runLen = (run.text as NSString).length
            if caretOffset < cumulative + runLen {
                let localOffset = caretOffset - cumulative
                let fraction = runLen > 0 ? CGFloat(localOffset) / CGFloat(runLen) : 1.0
                let cocoaFrame = AXHelper.cocoaRect(fromAccessibilityRect: run.frame)
                let caretX = cocoaFrame.minX + fraction * cocoaFrame.width
                return CaretGeometryResult(
                    rect: CGRect(
                        x: caretX, y: cocoaFrame.minY, width: 2, height: cocoaFrame.height),
                    quality: .derived,
                    observedCharWidth: charWidth
                )
            }
            cumulative += runLen
        }

        // A tiny overrun can happen when browsers omit newline glue from child text runs. A large
        // overrun means the run list is incomplete or polluted by non-editor labels (Gmail tracking
        // banners are exposed this way), so anchoring to the last run would jump the overlay to
        // unrelated UI.
        let missingTextTolerance = 2
        guard caretOffset <= cumulative + missingTextTolerance, let lastRun = textRuns.last else {
            return nil
        }

        let lastFrame = AXHelper.cocoaRect(fromAccessibilityRect: lastRun.frame)
        return CaretGeometryResult(
            rect: CGRect(x: lastFrame.maxX, y: lastFrame.minY, width: 2, height: lastFrame.height),
            quality: .derived,
            observedCharWidth: charWidth
        )
    }

    /// Chromium-based editors sometimes nest text runs under intermediary wrappers (`AXGroup`,
    /// anonymous containers, etc.). Walking only one child level misses those runs and forces
    /// Branch 3 (`AXFrame`) fallback. We scan descendants in pre-order so cumulative text length
    /// still tracks visual reading order in most editor trees.
    private func collectStaticTextElements(from root: AXUIElement) -> [AXUIElement] {
        let maxDepth = 8
        let maxNodes = 300
        var visitedNodes = 0
        var seen = Set<String>()
        var elements: [AXUIElement] = []

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth, visitedNodes < maxNodes else {
                return
            }

            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else {
                return
            }

            visitedNodes += 1

            let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
            if role == kAXStaticTextRole as String,
                let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element),
                !text.isEmpty,
                let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element),
                !frame.isEmpty {
                elements.append(element)
            }

            guard depth < maxDepth else {
                return
            }

            for child in AXHelper.childElements(of: element) {
                walk(child, depth: depth + 1)
            }
        }

        for child in AXHelper.childElements(of: root) {
            walk(child, depth: 1)
        }

        return elements
    }

    /// Reads the current text and frame of each leaf and returns them in visual reading order.
    /// Returns nil when a leaf no longer reports the static-text role — the signal that a cached
    /// element list is stale and the caller must re-walk. Leaves that read empty are skipped rather
    /// than treated as stale, since a line can be momentarily empty mid-edit.
    private func textRuns(fromElements elements: [AXUIElement]) -> [(text: String, frame: CGRect)]? {
        var runs: [(text: String, frame: CGRect)] = []
        for element in elements {
            guard AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element)
                == kAXStaticTextRole as String else {
                return nil
            }
            guard let text = AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element),
                !text.isEmpty,
                let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element),
                !frame.isEmpty else {
                continue
            }
            runs.append((text, frame))
        }

        return runs.sorted { lhs, rhs in
            let lhsFrame = AXHelper.cocoaRect(fromAccessibilityRect: lhs.frame)
            let rhsFrame = AXHelper.cocoaRect(fromAccessibilityRect: rhs.frame)
            // Bucket midY into fixed slots so every pair of runs on the same visual line maps to
            // the same bucket. A direct `abs(Δ) > tolerance` comparison is non-transitive (A~B, B~C,
            // but A≁C), which yields an undefined sort order and can map cumulative offsets to the
            // wrong run — placing ghost text on the wrong line.
            let lineTolerance: CGFloat = 4
            let lhsBucket = (lhsFrame.midY / lineTolerance).rounded(.toNearestOrAwayFromZero)
            let rhsBucket = (rhsFrame.midY / lineTolerance).rounded(.toNearestOrAwayFromZero)
            if lhsBucket != rhsBucket {
                return lhsBucket > rhsBucket
            }
            return lhsFrame.minX < rhsFrame.minX
        }
    }

    /// One-shot run collection for callers that don't cache (e.g. line-height estimation).
    private func collectStaticTextRuns(from root: AXUIElement) -> [(text: String, frame: CGRect)] {
        textRuns(fromElements: collectStaticTextElements(from: root)) ?? []
    }

    /// Confirms a BoundsForRange result actually belongs to the focused field's neighborhood.
    ///
    /// `AXHelper.validatedCocoaTextRect` falls back to a best-effort flipped rect when neither
    /// coordinate-system candidate lands inside the anchor — fine when only known-good elements
    /// could even reach that helper (the old `supportsBoundsForRange` gate), but unsafe now that
    /// any AX node may respond non-nil. We treat the same anchor halo as a hard accept/reject
    /// boundary so the resolver falls through to the next branch instead of trusting a rect
    /// whose midpoint lies nowhere near where the user is typing.
    ///
    /// Returns `true` when no anchor is supplied (cannot validate, preserve legacy behavior) or
    /// when the rect's midpoint sits inside the anchor expanded by an 80pt halo — the same
    /// tolerance `AXHelper.validatedCocoaTextRect` uses to decide between coordinate systems.
    ///
    /// Internal (not private) so tests can exercise the accept/reject boundary directly, without
    /// needing a live AX element that returns a controllable rect.
    func rectIsNearAnchor(_ cocoaRect: CGRect, anchor: CGRect?) -> Bool {
        guard let anchor, !anchor.isEmpty else {
            return true
        }
        let tolerance: CGFloat = 80
        let expanded = anchor.insetBy(dx: -tolerance, dy: -tolerance)
        return expanded.contains(CGPoint(x: cocoaRect.midX, y: cocoaRect.midY))
    }

    /// `AXBoundsForRange(location - 1, 1)` should describe one rendered character. Chromium can
    /// instead return the full wrapped text-run containing that character, which looks plausible
    /// by position but is hundreds of points wide. Deriving a caret from that rectangle pins the
    /// overlay to the run's far edge, so reject it and let text-run fallbacks try a tighter source.
    func looksLikeOversizedSingleCharacterRange(_ rect: CGRect, anchor: CGRect?) -> Bool {
        guard !rect.isEmpty else {
            return false
        }

        let absoluteMaxCharacterWidth: CGFloat = 80
        guard let anchor, !anchor.isEmpty else {
            return rect.width > absoluteMaxCharacterWidth
        }

        return rect.width > min(anchor.width * 0.35, absoluteMaxCharacterWidth)
    }

    /// Outlook-on-the-web has a different Chromium failure from Gmail: the one-character range
    /// can be normal height and very narrow, but pinned to the editable field's left edge even as
    /// the selection offset advances. That shape passes width/height guards, yet deriving a caret
    /// from it parks ghost text on the wrong line. When the plain text says the caret is already
    /// inside the current logical line, reject this left-edge range and let child text-run geometry
    /// or frame fallback try next.
    func looksLikeStaleLineStartRange(
        _ rect: CGRect,
        anchor: CGRect?,
        text: String?,
        selection: NSRange
    ) -> Bool {
        guard let anchor, !anchor.isEmpty, let text, !text.isEmpty, !rect.isEmpty else {
            return false
        }

        let nsText = text as NSString
        guard selection.location > 1, selection.location <= nsText.length else {
            return false
        }

        let prefix = nsText.substring(to: selection.location)
        let currentLinePrefix = prefix.components(separatedBy: .newlines).last ?? prefix
        guard (currentLinePrefix as NSString).length > 1 else {
            return false
        }

        let leftEdgeTolerance: CGFloat = 4
        let rangeTrailingEdge = rect.maxX
        return abs(rangeTrailingEdge - anchor.minX) <= leftEdgeTolerance
    }

    /// Chromium can answer `BoundsForRange(location - 1, 1)` with the union of multiple rendered
    /// lines. That rectangle is still near the field, so halo validation cannot catch it, but its
    /// height is much larger than the real text-run line height exposed by nearby `AXStaticText`
    /// descendants. When we can measure those descendants, reject the union and let later fallbacks
    /// search for marker geometry or use a conservative frame estimate.
    private func looksLikeMultilineRangeUnion(_ rect: CGRect, in element: AXUIElement) -> Bool {
        let lineHeights = collectStaticTextRuns(from: element)
            .map { AXHelper.cocoaRect(fromAccessibilityRect: $0.frame).height }
            .filter { $0 >= 8 }
            .sorted()

        guard !lineHeights.isEmpty else {
            return false
        }

        guard let largestObservedLineHeight = lineHeights.last else {
            return false
        }

        return rect.height > max(largestObservedLineHeight * 1.8, largestObservedLineHeight + 24)
    }

    /// Some browser-based editors return a full line fragment for a zero-length range instead of
    /// a narrow caret box. Collapse those wide rects back down to a caret-like anchor.
    private func normalizedCaretRect(fromZeroLengthRangeRect rect: CGRect) -> CGRect {
        guard !rect.isEmpty else {
            return rect
        }

        let normalizedWidth: CGFloat = 2
        if rect.width <= 6 {
            return CGRect(x: rect.minX, y: rect.minY, width: normalizedWidth, height: rect.height)
        }

        return CGRect(x: rect.minX, y: rect.minY, width: normalizedWidth, height: rect.height)
    }
}
