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

        // Find which child contains the caret by matching parent selection against cumulative
        // text lengths. AX selections use UTF-16 offsets, so we match on NSString length.
        let caretOffset = parentSelection.location
        var cumulative = 0
        for run in textRuns {
            let runLen = (run.text as NSString).length
            if caretOffset <= cumulative + runLen {
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

        // Caret is past all children (e.g. newline not included in child text).
        // Use the last child's trailing edge.
        let lastFrame = AXHelper.cocoaRect(fromAccessibilityRect: textRuns.last!.frame)
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
