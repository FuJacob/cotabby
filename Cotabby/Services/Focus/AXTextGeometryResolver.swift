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
    /// Content edges measured from the same child text-run frames (see `ObservedContentEdges`).
    /// Nil when no child frame data was available.
    let observedContentEdges: ObservedContentEdges?
    /// Extra source granularity for diagnostics (e.g. which caret-to-run mapping mode ran).
    /// Surfaces in the debug caret badge and the structured logs via the caret source label.
    let sourceDetail: String?

    init(
        rect: CGRect,
        quality: CaretGeometryQuality,
        observedCharWidth: CGFloat? = nil,
        observedContentEdges: ObservedContentEdges? = nil,
        sourceDetail: String? = nil
    ) {
        self.rect = rect
        self.quality = quality
        self.observedCharWidth = observedCharWidth
        self.observedContentEdges = observedContentEdges
        self.sourceDetail = sourceDetail
    }
}

@MainActor
struct AXTextGeometryResolver {
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
        textSelection: NSRange? = nil
    ) -> CaretGeometryResult? {
        let selectionInTextValue = textSelection ?? selection

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
            if rectIsNearAnchor(cocoaRect, anchor: cocoaAnchorFrame) {
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
                parentSelection: selectionInTextValue,
                parentText: parentText
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
                    selection: selectionInTextValue
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

    /// Walks AXStaticText children of a text container to find the one containing the caret,
    /// then estimates caret position proportionally within that child's AXFrame. This is the
    /// primary caret resolution path for Gmail, Outlook, and other Chromium editors where
    /// BoundsForRange fails but per-text-run child frames are precise.
    private func resolveCaretFromChildTextRuns(
        element: AXUIElement,
        parentSelection: NSRange,
        parentText: String
    ) -> CaretGeometryResult? {
        let parentTextLength = (parentText as NSString).length
        guard parentSelection.location <= parentTextLength else {
            return nil
        }

        let textRuns = collectStaticTextRuns(from: element)

        guard !textRuns.isEmpty else { return nil }

        // Derive the average character width from the child frames — this is a direct measurement
        // of the actual rendered font, not a guess. We aggregate across all children so a single
        // short run doesn't skew the estimate.
        var totalChars = 0
        var totalWidth: CGFloat = 0
        for run in textRuns {
            totalChars += (run.text as NSString).length
            totalWidth += run.frame.width
        }
        let charWidth: CGFloat? = totalChars > 0 ? totalWidth / CGFloat(totalChars) : nil

        // Measure the content edges from the same frames: the leftmost run's leading edge and the
        // topmost run's top edge reveal the field's real padding, which `AXFrame` hides. The caret
        // layout estimator anchors to these instead of guessed insets.
        let cocoaRunFrames = textRuns.map { AXHelper.cocoaRect(fromAccessibilityRect: $0.frame) }
        let contentEdges: ObservedContentEdges?
        if let leftX = cocoaRunFrames.map(\.minX).min(),
            let topY = cocoaRunFrames.map(\.maxY).max() {
            contentEdges = ObservedContentEdges(leftX: leftX, topY: topY)
        } else {
            contentEdges = nil
        }

        // Map the caret offset to a run by aligning run texts inside the parent value (see
        // `caretRunPlacement`). The run frame's Y is a real rendered line position, so a correct
        // run choice is what makes derived geometry trustworthy vertically.
        guard let placement = Self.caretRunPlacement(
            runTexts: textRuns.map(\.text),
            parentText: parentText,
            caretOffset: parentSelection.location
        ) else {
            return nil
        }

        let runFrame = cocoaRunFrames[placement.runIndex]
        let caretX = runFrame.minX + placement.fraction * runFrame.width
        return CaretGeometryResult(
            rect: CGRect(x: caretX, y: runFrame.minY, width: 2, height: runFrame.height),
            quality: .derived,
            observedCharWidth: charWidth,
            observedContentEdges: contentEdges,
            sourceDetail: placement.mode.rawValue
        )
    }

    /// Where the caret landed among the child text runs.
    ///
    /// Mapping is text-alignment based: each run's text is located inside the parent value, and
    /// the caret offset (a parent-value coordinate) is tested against the matched ranges. The
    /// previous cumulative-length mapping silently assumed the parent value is the run texts
    /// concatenated with nothing in between; Chromium editors separate blocks with newlines the
    /// runs do not contain, so every line break before the caret dragged the mapping one character
    /// deeper — several paragraphs in, the caret landed whole visual lines below its real run.
    ///
    /// Real captured values forced three hardenings beyond plain sequential search:
    ///   - Whitespace variants: hosts mix non-breaking and plain spaces between the parent value
    ///     and run texts, so matching runs on a length-preserving normalized form.
    ///   - Word-boundary anchoring: flattened values can fuse adjacent blocks with no separator at
    ///     all ("i'm"+"hi" → "i'mhi"), so a short run like "hi" must not match inside a fused
    ///     clump it does not belong to. Pass one only accepts boundary-clean matches.
    ///   - Gap fill: runs rejected by the boundary rule (their real occurrence IS fused) are
    ///     re-searched in pass two, constrained between their already-anchored neighbors, where a
    ///     non-boundary match cannot land in the wrong region.
    enum CaretRunMappingMode: String, Equatable {
        /// Every run anchored inside the parent value.
        case aligned = "runs-aligned"
        /// Some runs could not be anchored and were skipped; the caret mapped against the rest.
        case partiallyAligned = "runs-partial"
        /// No run could be anchored; fell back to the legacy cumulative-length walk.
        case legacyCumulative = "runs-legacy"
    }

    struct CaretRunPlacement: Equatable {
        let runIndex: Int
        /// Position inside the run: 0 is the leading edge, 1 the trailing edge.
        let fraction: CGFloat
        let mode: CaretRunMappingMode
    }

    /// Internal (not private) so the mapping math is unit-testable without live AX elements.
    static func caretRunPlacement(
        runTexts: [String],
        parentText: String,
        caretOffset: Int
    ) -> CaretRunPlacement? {
        guard !runTexts.isEmpty else {
            return nil
        }
        let parent = normalizedForMatching(parentText) as NSString
        let normalizedRuns = runTexts.map(normalizedForMatching)
        let caret = min(max(caretOffset, 0), parent.length)

        let anchored = anchoredRunRanges(normalizedRuns: normalizedRuns, parent: parent)
        guard !anchored.isEmpty else {
            return legacyCumulativePlacement(runTexts: runTexts, caretOffset: caret)
        }
        let mode: CaretRunMappingMode = anchored.count == runTexts.count
            ? .aligned
            : .partiallyAligned
        return placementAmongAnchors(anchored, caret: caret, mode: mode)
    }

    /// Anchors each run's text inside the parent value. Pass one accepts only boundary-clean
    /// matches, in order. Pass two retries the rejected runs with a plain search, but only inside
    /// the window between their nearest anchored neighbors, where a fused match cannot land in the
    /// wrong region. Returns the anchored (runIndex, range) pairs in document order.
    private static func anchoredRunRanges(
        normalizedRuns: [String],
        parent: NSString
    ) -> [(runIndex: Int, range: NSRange)] {
        var matchedRanges = [NSRange?](repeating: nil, count: normalizedRuns.count)

        var searchLocation = 0
        for (index, text) in normalizedRuns.enumerated() where !text.isEmpty {
            let found = boundaryCleanRange(of: text as NSString, in: parent, from: searchLocation)
            if found.location != NSNotFound {
                matchedRanges[index] = found
                searchLocation = found.location + found.length
            }
        }

        var lowerBound = 0
        for (index, text) in normalizedRuns.enumerated() {
            if let matched = matchedRanges[index] {
                lowerBound = matched.location + matched.length
                continue
            }
            let upperBound = matchedRanges[(index + 1)...]
                .compactMap { $0 }
                .first?.location ?? parent.length
            guard !text.isEmpty, upperBound > lowerBound else {
                continue
            }
            let window = NSRange(location: lowerBound, length: upperBound - lowerBound)
            let found = parent.range(of: text, options: [], range: window)
            if found.location != NSNotFound {
                matchedRanges[index] = found
                lowerBound = found.location + found.length
            }
        }

        return matchedRanges.enumerated().compactMap { index, range in
            range.map { (index, $0) }
        }
    }

    /// Maps the caret offset onto the anchored runs: inside a range is proportional, inside a
    /// separator gap snaps to the nearest rendered edge (a line break or a blank line the runs
    /// cannot represent — either choice is at most one line from the truth, which text alone
    /// cannot resolve), and beyond every anchor lands on the last run's trailing edge.
    private static func placementAmongAnchors(
        _ anchored: [(runIndex: Int, range: NSRange)],
        caret: Int,
        mode: CaretRunMappingMode
    ) -> CaretRunPlacement {
        for (position, entry) in anchored.enumerated() {
            if caret < entry.range.location {
                if position > 0 {
                    let previous = anchored[position - 1]
                    let previousEnd = previous.range.location + previous.range.length
                    if caret - previousEnd <= entry.range.location - caret {
                        return CaretRunPlacement(runIndex: previous.runIndex, fraction: 1, mode: mode)
                    }
                }
                return CaretRunPlacement(runIndex: entry.runIndex, fraction: 0, mode: mode)
            }
            if caret <= entry.range.location + entry.range.length {
                let fraction = entry.range.length > 0
                    ? CGFloat(caret - entry.range.location) / CGFloat(entry.range.length)
                    : 1
                return CaretRunPlacement(runIndex: entry.runIndex, fraction: fraction, mode: mode)
            }
        }

        return CaretRunPlacement(
            runIndex: anchored[anchored.count - 1].runIndex,
            fraction: 1,
            mode: mode
        )
    }

    /// Maps non-breaking space variants to a plain space so matching survives hosts that mix the
    /// two between the parent value and run texts. Every replacement is a single UTF-16 unit for a
    /// single UTF-16 unit, so matched ranges stay valid coordinates in the original string.
    private static func normalizedForMatching(_ text: String) -> String {
        String(text.map { character in
            character == "\u{00A0}" || character == "\u{2007}" || character == "\u{202F}"
                ? " "
                : character
        })
    }

    /// First occurrence of `needle` at or after `location` whose edges look like real token
    /// boundaries. A match is boundary-clean on a side when either the needle's edge character or
    /// the adjacent parent character is not alphanumeric — i.e. we only reject matches that would
    /// split a longer alphanumeric clump, the signature of flattened block boundaries.
    private static func boundaryCleanRange(
        of needle: NSString,
        in haystack: NSString,
        from location: Int
    ) -> NSRange {
        var searchStart = location
        while searchStart < haystack.length {
            let remaining = NSRange(location: searchStart, length: haystack.length - searchStart)
            let found = haystack.range(of: needle as String, options: [], range: remaining)
            guard found.location != NSNotFound else {
                return found
            }
            let cleanBefore = found.location == 0
                || !isAlphanumeric(haystack.character(at: found.location - 1))
                || !isAlphanumeric(needle.character(at: 0))
            let endIndex = found.location + found.length
            let cleanAfter = endIndex >= haystack.length
                || !isAlphanumeric(haystack.character(at: endIndex))
                || !isAlphanumeric(needle.character(at: needle.length - 1))
            if cleanBefore && cleanAfter {
                return found
            }
            searchStart = found.location + 1
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    /// UTF-16 unit classification for the boundary rule. Surrogate halves (emoji, rare CJK) are
    /// treated as alphanumeric so a match never anchors mid-character.
    private static func isAlphanumeric(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else {
            return true
        }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func legacyCumulativePlacement(
        runTexts: [String],
        caretOffset: Int
    ) -> CaretRunPlacement {
        var cumulative = 0
        for (index, text) in runTexts.enumerated() {
            let length = (text as NSString).length
            if caretOffset <= cumulative + length {
                let local = caretOffset - cumulative
                let fraction = length > 0 ? CGFloat(local) / CGFloat(length) : 1
                return CaretRunPlacement(runIndex: index, fraction: fraction, mode: .legacyCumulative)
            }
            cumulative += length
        }
        return CaretRunPlacement(runIndex: runTexts.count - 1, fraction: 1, mode: .legacyCumulative)
    }

    /// Chromium-based editors sometimes nest text runs under intermediary wrappers (`AXGroup`,
    /// anonymous containers, etc.). Walking only one child level misses those runs and forces
    /// Branch 3 (`AXFrame`) fallback. We scan descendants in pre-order so cumulative text length
    /// still tracks visual reading order in most editor trees.
    private func collectStaticTextRuns(from root: AXUIElement) -> [(text: String, frame: CGRect)] {
        let maxDepth = 8
        let maxNodes = 300
        var visitedNodes = 0
        var seen = Set<String>()
        var runs: [(text: String, frame: CGRect)] = []

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
                runs.append((text, frame))
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

        return runs
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
