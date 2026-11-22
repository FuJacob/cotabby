import CoreGraphics
import Foundation

/// Pure selection policy between OCR and prompting. The screenshot generator supplies cleaned
/// lines and the focused field's normalized bounds; this helper keeps nearby conversation/document
/// text ahead of distant window chrome, then restores reading order. It owns no tasks or history.
nonisolated enum VisualContextExcerptSelector {
    /// A ranked OCR line exists only during selection; its index restores reading order.
    private struct Candidate {
        let index: Int
        let text: String
        let score: Double
    }

    static func select(
        lines: [OCRTextHygiene.OCRLine],
        fieldText: String,
        focusBounds: CGRect?,
        maxCharacters: Int
    ) -> String {
        guard maxCharacters > 0 else { return "" }
        var seen = Set<String>()
        let candidates = lines.enumerated().compactMap { index, line -> Candidate? in
            if let bounds = line.boundingBox, let focus = focusBounds,
               isFocusedFieldOrBelow(bounds, focus: focus) {
                return nil
            }
            let cleaned = OCRTextHygiene.clean(lines: [line], fieldText: fieldText, maxChars: maxCharacters)
            // Confidence/line hygiene has already removed corrupt recognition. The legacy
            // token-level OCR filter drops every number and unrecognized English word, erasing
            // deadlines, amounts and names. Preserve those facts in the richer local excerpt.
            let text = PromptContextSanitizer.sanitize(cleaned)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return nil }
            let score: Double
            if let bounds = line.boundingBox, let focus = focusBounds {
                // A neighboring message in the editor's column outranks a equally close sidebar.
                let sameColumn = bounds.maxX >= focus.minX && bounds.minX <= focus.maxX
                score = abs(bounds.midY - focus.midY) + (sameColumn ? 0 : 1)
            } else {
                // OCR arrives in reading order. Without geometry, favor the latest visible lines
                // rather than spending the entire budget on the top toolbar and oldest messages.
                score = -Double(index)
            }
            return Candidate(index: index, text: text, score: score)
        }
        var remaining = maxCharacters
        var selected: [(Int, String)] = []
        for candidate in candidates.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }) {
            let index = candidate.index
            let text = candidate.text
            let separator = selected.isEmpty ? 0 : 1
            guard remaining > separator else { break }
            if text.count + separator <= remaining {
                selected.append((index, text))
                remaining -= text.count + separator
            } else if selected.isEmpty {
                selected.append((index, String(text.prefix(remaining))))
                remaining = 0
            }
        }
        return selected.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }

    /// Whether an OCR line is the focused field itself or sits under its caret line, in the
    /// field's column (Vision's bottom-left space, so "below" is a smaller y). That is the composer:
    /// a copy of the draft read before the latest keystrokes (so the field-text strip cannot match
    /// it) and the composer's own chrome. Ranked first by proximity, it led the excerpt, and a base
    /// model continued the draft by copying what followed it on screen: "what is in USA" became
    /// "what is in USA 4 5.6 Sol", the attachment icon and model picker under ChatGPT's composer.
    /// The field's text reaches the prompt through Accessibility, so nothing is lost; lines above
    /// the field (the conversation) and in other columns are kept.
    static func isFocusedFieldOrBelow(_ bounds: CGRect, focus: CGRect) -> Bool {
        let sameColumn = bounds.maxX >= focus.minX && bounds.minX <= focus.maxX
        return sameColumn && bounds.midY <= focus.maxY
    }
}
