import AppKit
import CoreGraphics
import Foundation

/// Computes the visual line layout for ghost text before `OverlayController` renders it.
///
/// Keeping this as a pure value helper gives us a clear boundary: the helper answers "where should
/// the text lines go?", while `OverlayController` answers "how do we place the non-activating
/// AppKit panel?". That split matters because wrapping bugs are layout bugs, not window lifecycle
/// bugs.
struct GhostSuggestionLayout: Equatable {
    struct Line: Equatable, Identifiable {
        let index: Int
        let text: String
        let leadingIndent: CGFloat
        let showsKeycap: Bool

        var id: Int { index }
    }

    let lines: [Line]
    /// For LTR, the left edge of the panel. For RTL, the right-edge anchor — `panelFrame()`
    /// subtracts the content width to derive the actual AppKit origin.
    let panelOriginX: CGFloat
    let lineHeight: CGFloat
    let topLineCenterOffsetFromCaret: CGFloat
    let isRightToLeft: Bool
    /// True when wrapped lines start at the host's measured text margin rather than the field frame.
    /// Diagnostics read this instead of inferring it from whether a measurement merely existed: a
    /// single-line suggestion only ever sits at the caret, and a margin the screen edge overrides or
    /// a frame too narrow to use is dropped, so "a margin was measured" does not mean "the margin
    /// was used".
    var wrappedLinesFollowHostMargin: Bool = false

    private enum Metrics {
        static let caretGap: CGFloat = 6
        static let inputHorizontalPadding: CGFloat = 8
        static let fallbackScreenMargin: CGFloat = 16
        static let minimumLineWidth: CGFloat = 48
        static let estimatedKeycapAndSpacingWidth: CGFloat = 36
        static let lineHeightMultiplier: CGFloat = 1.25
    }

    /// Inputs for measuring rendered text width: the size, the AX-observed average char width when
    /// available, and the host field font used for the fallback measurement. Bundled so the wrapping
    /// helpers stay within a small parameter count and so width is measured with the rendered glyphs.
    private struct TextMeasure {
        let fontSize: CGFloat
        let observedCharWidth: CGFloat?
        let font: NSFont?
    }

    static func make(
        text: String,
        geometry: SuggestionOverlayGeometry,
        fontSize: CGFloat,
        visibleFrame: CGRect,
        showsAcceptanceHint: Bool = true,
        font: NSFont? = nil
    ) -> GhostSuggestionLayout {
        let normalizedText = normalizedDisplayText(text)
        let lineHeight = ceil(fontSize * Metrics.lineHeightMultiplier)
        let isRTL = geometry.isRightToLeft
        let measure = TextMeasure(
            fontSize: fontSize,
            observedCharWidth: geometry.observedCharWidth,
            font: font
        )
        // When the keycap is hidden the text can use the full width, so we stop reserving room for it.
        let keycapReservation = showsAcceptanceHint ? Metrics.estimatedKeycapAndSpacingWidth : 0
        let region = usableRegion(
            geometry: geometry,
            visibleFrame: visibleFrame
        )
        let usableFrame = region.frame

        // Direction-dependent anchor and budget.
        // LTR: anchor at the right edge of the caret, budget extends rightward.
        // RTL: anchor at the left edge of the caret, budget extends leftward.
        //
        // The anchor sits flush against the caret with no padding, because inline ghost text has to
        // read as a continuation of the host's own line. `normalizedDisplayText` deliberately keeps
        // the suggestion's leading space when it has one, so word spacing is already carried by the
        // text itself; adding a gap on top rendered it as a space *plus* a gap. A gap is outright
        // wrong for a mid-word continuation ("calc" -> "ulates"), where any padding visibly breaks
        // the word. `Metrics.caretGap` still applies to the fallback usable-region bounds below,
        // where it serves a different purpose — keeping the region off the caret.
        let firstLineAnchor: CGFloat
        let firstLineBudget: CGFloat
        if isRTL {
            firstLineAnchor = min(
                max(geometry.caretRect.minX, usableFrame.minX),
                usableFrame.maxX
            )
            firstLineBudget = max(
                0,
                firstLineAnchor - usableFrame.minX - keycapReservation
            )
        } else {
            firstLineAnchor = min(
                max(geometry.caretRect.maxX, usableFrame.minX),
                usableFrame.maxX
            )
            firstLineBudget = max(
                0,
                usableFrame.maxX - firstLineAnchor - keycapReservation
            )
        }

        // Wrapped lines start at the overflow edge — the host's measured text margin when there is
        // one — and share the caret line's right bound.
        let overflowBudget = max(
            Metrics.minimumLineWidth,
            usableFrame.maxX - region.overflowMinX - keycapReservation
        )

        let singleLineFits = !normalizedText.contains("\n")
            && measuredWidth(of: normalizedText, using: measure) <= firstLineBudget

        if singleLineFits {
            return GhostSuggestionLayout(
                lines: [
                    Line(index: 0, text: normalizedText, leadingIndent: 0, showsKeycap: showsAcceptanceHint)
                ],
                panelOriginX: firstLineAnchor,
                lineHeight: lineHeight,
                topLineCenterOffsetFromCaret: 0,
                isRightToLeft: isRTL,
                // A single line always sits flush against the caret; a measured margin only ever
                // positions wrapped lines.
                wrappedLinesFollowHostMargin: false
            )
        }

        // Multi-line wrapping: split the text first, then place the panel, because where it starts
        // depends on whether the first line landed on the caret's line.
        var remainingText = normalizedText
        var lineTexts: [String] = []
        var startsBelowCaret = false

        if firstLineBudget >= Metrics.minimumLineWidth {
            let split = splitPrefix(
                from: remainingText,
                maxWidth: firstLineBudget,
                using: measure
            )
            if !split.line.isEmpty {
                lineTexts.append(split.line)
                remainingText = split.remainder
            } else {
                startsBelowCaret = true
            }
        } else {
            startsBelowCaret = true
        }

        while !remainingText.isEmpty {
            let split = splitPrefix(
                from: remainingText,
                maxWidth: overflowBudget,
                using: measure
            )
            guard !split.line.isEmpty else {
                break
            }

            lineTexts.append(split.line)
            remainingText = split.remainder
        }

        if lineTexts.isEmpty {
            lineTexts.append(normalizedText)
            startsBelowCaret = true
        }

        // RTL panels anchor at the region's right edge, with the caret line indented from it. LTR
        // panels start at whichever lies further left, the caret or the overflow margin, and each
        // line is indented from there: the caret's line to the caret, wrapped lines to the margin.
        // A margin right of the caret — a first-line indent measured on another line, a centred
        // line — therefore indents the wrapped lines instead of pushing the first line off the caret.
        let caretLineIsFirst = !startsBelowCaret
        let panelOriginX: CGFloat
        if isRTL {
            panelOriginX = usableFrame.maxX
        } else {
            panelOriginX = caretLineIsFirst
                ? min(firstLineAnchor, region.overflowMinX)
                : region.overflowMinX
        }
        let caretLineIndent = isRTL ? panelOriginX - firstLineAnchor : firstLineAnchor - panelOriginX
        let overflowIndent = isRTL ? 0 : region.overflowMinX - panelOriginX

        let finalLines = lineTexts.enumerated().map { offset, text in
            Line(
                index: offset,
                text: text,
                leadingIndent: offset == 0 && caretLineIsFirst ? caretLineIndent : overflowIndent,
                showsKeycap: showsAcceptanceHint && offset == lineTexts.count - 1
            )
        }

        return GhostSuggestionLayout(
            lines: finalLines,
            panelOriginX: panelOriginX,
            lineHeight: lineHeight,
            topLineCenterOffsetFromCaret: startsBelowCaret ? -lineHeight : 0,
            isRightToLeft: isRTL,
            // Wrapped lines start at the overflow edge, which is the host's margin when one fed it.
            wrappedLinesFollowHostMargin: region.usesHostContentEdge
        )
    }

    func panelFrame(for contentSize: CGSize, caretRect: CGRect) -> CGRect {
        // Use the height the text actually rendered at, not the `fontSize * lineHeightMultiplier`
        // estimate in `lineHeight`. The panel is sized by SwiftUI's `fittingSize`, and the two
        // disagree by a couple of points in practice (a 17.94pt ghost in Word measured 21pt tall
        // against an assumed 23pt), which offset the ghost vertically by exactly that difference.
        // Every line in the stack is laid out identically, so dividing by the line count recovers
        // the top line's real height — and that is the line the caret has to align with.
        let renderedLineHeight = lines.isEmpty
            ? lineHeight
            : contentSize.height / CGFloat(lines.count)
        let topLineCenterY = caretRect.midY + topLineCenterOffsetFromCaret
        let originY = topLineCenterY - contentSize.height + (renderedLineHeight / 2)
        let originX = isRightToLeft ? panelOriginX - contentSize.width : panelOriginX

        return CGRect(
            origin: CGPoint(x: originX, y: originY),
            size: contentSize
        )
    }

    /// Where ghost text may run, split by the role a line plays.
    private struct UsableRegion {
        /// Bounds for the caret's own line, and the right edge for every line. On the left it is the
        /// field frame plus a nominal inset, never a measured margin: the caret's line can
        /// legitimately start left of that margin (a first-line indent measured on another line, a
        /// centred line), and ghost text on it must stay flush against the caret.
        let frame: CGRect
        /// Where wrapped lines start: the host's measured text margin when one applies, otherwise
        /// `frame.minX`.
        let overflowMinX: CGFloat
        /// True when `overflowMinX` is the host's measured margin.
        let usesHostContentEdge: Bool
    }

    private static func usableRegion(
        geometry: SuggestionOverlayGeometry,
        visibleFrame: CGRect
    ) -> UsableRegion {
        if let inputFrame = geometry.inputFrameRect?.standardized,
           inputFrame.width > Metrics.minimumLineWidth {
            let minX = max(
                inputFrame.minX + Metrics.inputHorizontalPadding,
                visibleFrame.minX + Metrics.fallbackScreenMargin
            )
            let maxX = min(
                inputFrame.maxX - Metrics.inputHorizontalPadding,
                visibleFrame.maxX - Metrics.fallbackScreenMargin
            )

            if maxX - minX > Metrics.minimumLineWidth {
                let frame = CGRect(x: minX, y: inputFrame.minY, width: maxX - minX, height: inputFrame.height)
                return regionApplyingMeasuredMargin(
                    to: frame,
                    inputFrame: inputFrame,
                    geometry: geometry,
                    visibleFrame: visibleFrame
                ) ?? UsableRegion(frame: frame, overflowMinX: frame.minX, usesHostContentEdge: false)
            }
        }

        // Fallback when no input frame is available. For LTR, use the area to the right
        // of the caret. For RTL, use the area to the left.
        let fallbackMinX: CGFloat
        let fallbackMaxX: CGFloat
        if geometry.isRightToLeft {
            fallbackMinX = visibleFrame.minX + Metrics.fallbackScreenMargin
            fallbackMaxX = geometry.caretRect.minX - Metrics.caretGap
        } else {
            fallbackMinX = geometry.caretRect.maxX + Metrics.caretGap
            fallbackMaxX = visibleFrame.maxX - Metrics.fallbackScreenMargin
        }

        let frame = CGRect(
            x: fallbackMinX,
            y: geometry.caretRect.minY,
            width: max(Metrics.minimumLineWidth, fallbackMaxX - fallbackMinX),
            height: geometry.caretRect.height
        )
        return UsableRegion(frame: frame, overflowMinX: frame.minX, usesHostContentEdge: false)
    }

    /// Applies the host's measured text margin to a frame-based region, or returns nil when there
    /// is no margin to trust.
    ///
    /// This matters most in document editors: Word's `AXFrame` is the whole page, roughly an inch
    /// wider than the text column on each side, so frame-based bounds put wrapped ghost text outside
    /// both of the margins the user's own text wraps to. The measured left edge fixes the left side
    /// exactly. It is clamped into the frame so a stale or mis-reported edge cannot push text off the
    /// field entirely.
    ///
    /// The right margin is never measured, so for a line-query margin — the source for page-shaped
    /// frames like Word's — it is mirrored from the left: symmetric margins are the overwhelmingly
    /// common layout, and the caret layout estimator makes the same assumption. The mirror is only
    /// used while it still lies right of the caret, because a host never draws past its own right
    /// margin; a caret beyond the mirror disproves the symmetry for this field. Run-measured edges
    /// come from web editors whose frame already hugs the text, so their right edge stays the frame's.
    ///
    /// Right-to-left layouts ignore the measurement: the left edge of an RTL line is its ragged end,
    /// not a margin.
    private static func regionApplyingMeasuredMargin(
        to frame: CGRect,
        inputFrame: CGRect,
        geometry: SuggestionOverlayGeometry,
        visibleFrame: CGRect
    ) -> UsableRegion? {
        guard !geometry.isRightToLeft, let edges = geometry.observedContentEdges else {
            return nil
        }

        let marginX = min(max(edges.leftX, inputFrame.minX), inputFrame.maxX)
        let overflowMinX = max(marginX, visibleFrame.minX + Metrics.fallbackScreenMargin)

        var maxX = frame.maxX
        let leftInset = marginX - inputFrame.minX
        if !edges.isRunMeasured, leftInset > Metrics.inputHorizontalPadding {
            let mirroredMaxX = inputFrame.maxX - leftInset
            if mirroredMaxX >= geometry.caretRect.maxX {
                maxX = min(maxX, mirroredMaxX)
            }
        }

        guard maxX - overflowMinX > Metrics.minimumLineWidth,
              maxX - frame.minX > Metrics.minimumLineWidth
        else {
            return nil
        }

        return UsableRegion(
            frame: CGRect(x: frame.minX, y: frame.minY, width: maxX - frame.minX, height: frame.height),
            overflowMinX: overflowMinX,
            // The screen margin can override the measured edge; only report it when it survived.
            usesHostContentEdge: overflowMinX == marginX
        )
    }

    /// The width `text` actually occupies as a single rendered ghost line: the normalized display
    /// string measured with the real render `font` via Core Text glyph layout (not the average
    /// char-width budget `measuredWidth` uses for wrapping). Used to slide the overlay by the exact
    /// width of accepted text so the remaining tail stays on the same pixels. Measuring the string
    /// (not a character count) keeps graphemes, surrogate pairs, and whitespace normalization correct.
    ///
    /// Note: a `width(before) - width(after)` advance double-counts the kerning pair at the
    /// accepted/remaining seam by a sub-point amount for proportional fonts (each side is measured
    /// without the other's adjacent glyph). That residual is far inside the overlay's caret drift
    /// tolerance, and the stability gate's re-anchor caps any accumulation under rapid acceptance.
    static func renderedWidth(of text: String, font: NSFont) -> CGFloat {
        let display = normalizedDisplayText(text)
        guard !display.isEmpty else { return 0 }
        return (display as NSString).size(withAttributes: [.font: font]).width
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let normalizedLines = lines.map { line -> String in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return "" }
            let joined = words.joined(separator: " ")
            return line.first?.isWhitespace == true ? " \(joined)" : joined
        }
        return normalizedLines.joined(separator: "\n")
    }

    private static func splitPrefix(
        from text: String,
        maxWidth: CGFloat,
        using measure: TextMeasure
    ) -> (line: String, remainder: String) {
        let source = text.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else {
            return ("", "")
        }

        let safeMaxWidth = max(maxWidth, Metrics.minimumLineWidth)

        // Explicit newline: force a line break at the first one.
        if let newlineIndex = source.firstIndex(of: "\n") {
            return splitAtNewline(
                source: source,
                newlineIndex: newlineIndex,
                maxWidth: maxWidth,
                using: measure
            )
        }

        if measuredWidth(of: source, using: measure) <= safeMaxWidth {
            return (source, "")
        }

        let characters = Array(source)
        var lastWhitespaceBreak: Int?

        for endIndex in characters.indices {
            let prefix = String(characters[...endIndex])
            if characters[endIndex].isWhitespace {
                lastWhitespaceBreak = endIndex + 1
            }

            if measuredWidth(of: prefix, using: measure) > safeMaxWidth {
                if let breakIndex = lastWhitespaceBreak, breakIndex > 0 {
                    let line = String(characters[..<breakIndex])
                        .trimmingCharacters(in: .whitespaces)
                    let remainder = String(characters[breakIndex...])
                        .trimmingCharacters(in: .whitespaces)
                    return (line, remainder)
                }

                let splitIndex = max(endIndex, 1)
                let line = String(characters[..<splitIndex])
                    .trimmingCharacters(in: .whitespaces)
                let remainder = String(characters[splitIndex...])
                    .trimmingCharacters(in: .whitespaces)
                return (line, remainder)
            }
        }

        return (text.trimmingCharacters(in: .whitespaces), "")
    }

    /// Splits `source` at its first explicit newline, width-wrapping the leading segment if it overflows.
    private static func splitAtNewline(
        source: String,
        newlineIndex: String.Index,
        maxWidth: CGFloat,
        using measure: TextMeasure
    ) -> (line: String, remainder: String) {
        let safeMaxWidth = max(maxWidth, Metrics.minimumLineWidth)
        let segment = String(source[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
        let afterIndex = source.index(after: newlineIndex)
        let afterNewline = afterIndex < source.endIndex
            ? String(source[afterIndex...]).trimmingCharacters(in: .whitespaces)
            : ""

        guard !segment.isEmpty else {
            return splitPrefix(from: afterNewline, maxWidth: maxWidth, using: measure)
        }

        if measuredWidth(of: segment, using: measure) <= safeMaxWidth {
            return (segment, afterNewline)
        }

        // Segment before newline is too wide — width-wrap it, keep post-newline as remainder.
        let widthSplit = splitPrefix(from: segment, maxWidth: maxWidth, using: measure)
        let combined: String
        if widthSplit.remainder.isEmpty {
            combined = afterNewline
        } else if afterNewline.isEmpty {
            combined = widthSplit.remainder
        } else {
            combined = widthSplit.remainder + "\n" + afterNewline
        }
        return (widthSplit.line, combined)
    }

    private static func measuredWidth(of text: String, using measure: TextMeasure) -> CGFloat {
        if let observedCharWidth = measure.observedCharWidth, observedCharWidth > 0 {
            return CGFloat((text as NSString).length) * observedCharWidth
        }

        // Measure with the host field's font when known so wrapping matches the rendered glyphs;
        // this matters most in monospace editors where the system font's advances differ.
        return (text as NSString).size(withAttributes: [
            .font: measure.font ?? NSFont.systemFont(ofSize: measure.fontSize)
        ]).width
    }
}
