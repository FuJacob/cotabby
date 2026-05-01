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
    let panelOriginX: CGFloat
    let lineHeight: CGFloat
    let topLineCenterOffsetFromCaret: CGFloat

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
        let usableFrame = usableTextFrame(
            geometry: geometry,
            visibleFrame: visibleFrame
        )
        let firstLineX = min(
            max(geometry.caretRect.maxX + Metrics.caretGap, usableFrame.minX),
            usableFrame.maxX
        )
        let firstLineBudget = max(
            0,
            usableFrame.maxX - firstLineX - Metrics.estimatedKeycapAndSpacingWidth
        )
        let overflowBudget = max(
            Metrics.minimumLineWidth,
            usableFrame.width - Metrics.estimatedKeycapAndSpacingWidth
        )

        let singleLineFits = measuredWidth(
            of: normalizedText,
            fontSize: fontSize,
            observedCharWidth: geometry.observedCharWidth
        ) <= firstLineBudget

        if singleLineFits {
            return GhostSuggestionLayout(
                lines: [
                    Line(index: 0, text: normalizedText, leadingIndent: 0, showsKeycap: true)
                ],
                panelOriginX: firstLineX,
                lineHeight: lineHeight,
                topLineCenterOffsetFromCaret: 0
            )
        }

        let panelOriginX = usableFrame.minX
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
                rawLines.append((split.line, firstLineX - panelOriginX))
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
            topLineCenterOffsetFromCaret: startsBelowCaret ? -lineHeight : 0
        )
    }

    func panelFrame(for contentSize: CGSize, caretRect: CGRect) -> CGRect {
        let topLineCenterY = caretRect.midY + topLineCenterOffsetFromCaret
        let originY = topLineCenterY - contentSize.height + (lineHeight / 2)

        return CGRect(
            origin: CGPoint(x: panelOriginX, y: originY),
            size: contentSize
        )
    }

    private static func usableTextFrame(
        geometry: SuggestionOverlayGeometry,
        visibleFrame: CGRect
    ) -> CGRect {
        let fallbackMinX = geometry.caretRect.maxX + Metrics.caretGap
        let fallbackMaxX = visibleFrame.maxX - Metrics.fallbackScreenMargin
        let fallbackFrame = CGRect(
            x: fallbackMinX,
            y: geometry.caretRect.minY,
            width: max(Metrics.minimumLineWidth, fallbackMaxX - fallbackMinX),
            height: geometry.caretRect.height
        )

        guard let inputFrame = geometry.inputFrameRect?.standardized,
              inputFrame.width > Metrics.minimumLineWidth
        else {
            return fallbackFrame
        }

        let minX = max(
            inputFrame.minX + Metrics.inputHorizontalPadding,
            visibleFrame.minX + Metrics.fallbackScreenMargin
        )
        let maxX = min(
            inputFrame.maxX - Metrics.inputHorizontalPadding,
            visibleFrame.maxX - Metrics.fallbackScreenMargin
        )

        guard maxX - minX > Metrics.minimumLineWidth else {
            return fallbackFrame
        }

        return CGRect(
            x: minX,
            y: inputFrame.minY,
            width: maxX - minX,
            height: inputFrame.height
        )
    }

    private static func normalizedDisplayText(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return text
        }

        let joined = words.joined(separator: " ")
        return text.first?.isWhitespace == true ? " \(joined)" : joined
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
