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

    private enum Metrics {
        static let caretGap: CGFloat = 6
        static let inputHorizontalPadding: CGFloat = 8
        static let fallbackScreenMargin: CGFloat = 16
        static let minimumLineWidth: CGFloat = 48
        static let estimatedKeycapAndSpacingWidth: CGFloat = 36
        static let lineHeightMultiplier: CGFloat = 1.25
    }

    static func make(
        text: String,
        geometry: SuggestionOverlayGeometry,
        fontSize: CGFloat,
        visibleFrame: CGRect
    ) -> GhostSuggestionLayout {
        let normalizedText = normalizedDisplayText(text)
        let lineHeight = ceil(fontSize * Metrics.lineHeightMultiplier)
        let isRTL = geometry.isRightToLeft
        let usableFrame = usableTextFrame(
            geometry: geometry,
            visibleFrame: visibleFrame
        )

        // Direction-dependent anchor and budget.
        // LTR: anchor at the right edge of the caret, budget extends rightward.
        // RTL: anchor at the left edge of the caret, budget extends leftward.
        let firstLineAnchor: CGFloat
        let firstLineBudget: CGFloat
        if isRTL {
            firstLineAnchor = min(
                max(geometry.caretRect.minX - Metrics.caretGap, usableFrame.minX),
                usableFrame.maxX
            )
            firstLineBudget = max(
                0,
                firstLineAnchor - usableFrame.minX - Metrics.estimatedKeycapAndSpacingWidth
            )
        } else {
            firstLineAnchor = min(
                max(geometry.caretRect.maxX + Metrics.caretGap, usableFrame.minX),
                usableFrame.maxX
            )
            firstLineBudget = max(
                0,
                usableFrame.maxX - firstLineAnchor - Metrics.estimatedKeycapAndSpacingWidth
            )
        }

        let overflowBudget = max(
            Metrics.minimumLineWidth,
            usableFrame.width - Metrics.estimatedKeycapAndSpacingWidth
        )

        let singleLineFits = !normalizedText.contains("\n") && measuredWidth(
            of: normalizedText,
            fontSize: fontSize,
            observedCharWidth: geometry.observedCharWidth
        ) <= firstLineBudget

        if singleLineFits {
            return GhostSuggestionLayout(
                lines: [
                    Line(index: 0, text: normalizedText, leadingIndent: 0, showsKeycap: true)
                ],
                panelOriginX: firstLineAnchor,
                lineHeight: lineHeight,
                topLineCenterOffsetFromCaret: 0,
                isRightToLeft: isRTL
            )
        }

        // Multi-line wrapping. The panel spans the full usable width so overflow lines can
        // use the entire field. The first line is indented to stay aligned with the caret.
        let panelOriginX = isRTL ? usableFrame.maxX : usableFrame.minX
        var remainingText = normalizedText
        var rawLines: [(text: String, leadingIndent: CGFloat)] = []
        var startsBelowCaret = false

        if firstLineBudget >= Metrics.minimumLineWidth {
            let split = splitPrefix(
                from: remainingText,
                maxWidth: firstLineBudget,
                fontSize: fontSize,
                observedCharWidth: geometry.observedCharWidth
            )
            if !split.line.isEmpty {
                let indent: CGFloat
                if isRTL {
                    indent = panelOriginX - firstLineAnchor
                } else {
                    indent = firstLineAnchor - panelOriginX
                }
                rawLines.append((split.line, indent))
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
                fontSize: fontSize,
                observedCharWidth: geometry.observedCharWidth
            )
            guard !split.line.isEmpty else {
                break
            }

            rawLines.append((split.line, 0))
            remainingText = split.remainder
        }

        if rawLines.isEmpty {
            rawLines.append((normalizedText, 0))
            startsBelowCaret = true
        }

        let finalLines = rawLines.enumerated().map { offset, rawLine in
            Line(
                index: offset,
                text: rawLine.text,
                leadingIndent: rawLine.leadingIndent,
                showsKeycap: offset == rawLines.count - 1
            )
        }

        return GhostSuggestionLayout(
            lines: finalLines,
            panelOriginX: panelOriginX,
            lineHeight: lineHeight,
            topLineCenterOffsetFromCaret: startsBelowCaret ? -lineHeight : 0,
            isRightToLeft: isRTL
        )
    }

    func panelFrame(for contentSize: CGSize, caretRect: CGRect) -> CGRect {
        let topLineCenterY = caretRect.midY + topLineCenterOffsetFromCaret
        let originY = topLineCenterY - contentSize.height + (lineHeight / 2)
        let originX = isRightToLeft ? panelOriginX - contentSize.width : panelOriginX

        return CGRect(
            origin: CGPoint(x: originX, y: originY),
            size: contentSize
        )
    }

    private static func usableTextFrame(
        geometry: SuggestionOverlayGeometry,
        visibleFrame: CGRect
    ) -> CGRect {
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
                return CGRect(
                    x: minX,
                    y: inputFrame.minY,
                    width: maxX - minX,
                    height: inputFrame.height
                )
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

        return CGRect(
            x: fallbackMinX,
            y: geometry.caretRect.minY,
            width: max(Metrics.minimumLineWidth, fallbackMaxX - fallbackMinX),
            height: geometry.caretRect.height
        )
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
        fontSize: CGFloat,
        observedCharWidth: CGFloat?
    ) -> (line: String, remainder: String) {
        let source = text.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else {
            return ("", "")
        }

        let safeMaxWidth = max(maxWidth, Metrics.minimumLineWidth)

        // Explicit newline: force a line break at the first one.
        if let newlineIndex = source.firstIndex(of: "\n") {
            let segment = String(source[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
            let afterIndex = source.index(after: newlineIndex)
            let afterNewline = afterIndex < source.endIndex
                ? String(source[afterIndex...]).trimmingCharacters(in: .whitespaces)
                : ""

            guard !segment.isEmpty else {
                return splitPrefix(from: afterNewline, maxWidth: maxWidth, fontSize: fontSize, observedCharWidth: observedCharWidth)
            }

            if measuredWidth(of: segment, fontSize: fontSize, observedCharWidth: observedCharWidth) <= safeMaxWidth {
                return (segment, afterNewline)
            }

            // Segment before newline is too wide — width-wrap it, keep post-newline as remainder.
            let widthSplit = splitPrefix(from: segment, maxWidth: maxWidth, fontSize: fontSize, observedCharWidth: observedCharWidth)
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

        if measuredWidth(of: source, fontSize: fontSize, observedCharWidth: observedCharWidth) <= safeMaxWidth {
            return (source, "")
        }

        let characters = Array(source)
        var lastWhitespaceBreak: Int?

        for endIndex in characters.indices {
            let prefix = String(characters[...endIndex])
            if characters[endIndex].isWhitespace {
                lastWhitespaceBreak = endIndex + 1
            }

            if measuredWidth(of: prefix, fontSize: fontSize, observedCharWidth: observedCharWidth) > safeMaxWidth {
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

    private static func measuredWidth(
        of text: String,
        fontSize: CGFloat,
        observedCharWidth: CGFloat?
    ) -> CGFloat {
        if let observedCharWidth, observedCharWidth > 0 {
            return CGFloat((text as NSString).length) * observedCharWidth
        }

        return (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]).width
    }
}
