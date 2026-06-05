import Foundation

/// File overview:
/// Shared value types for the inline `/macro` feature. These are intentionally small, `Equatable`,
/// and free of AppKit/Accessibility/CGEvent dependencies so every macro family stays pure and easy
/// to unit test. UI and runtime wiring live elsewhere.

/// A computed macro result: what to show in the single-row inline preview, and what to insert when
/// the user accepts. The two can differ (arithmetic keeps the worked expression, `5+5=10`, while a
/// date inserts the same value it previews).
struct MacroResult: Equatable {
    /// Text shown under the caret while the user types (for example `= 10` or `Jun 4, 2026`).
    let previewText: String
    /// Text that replaces the typed `/query` run on accept.
    let insertionText: String

    init(previewText: String, insertionText: String) {
        self.previewText = previewText
        self.insertionText = insertionText
    }

    /// Convenience for macros whose preview and inserted text are identical.
    init(_ value: String) {
        self.previewText = value
        self.insertionText = value
    }
}

/// A pure macro family. Implementations are deterministic given their injected clock and RNG, so the
/// whole macro layer is unit testable without AX, CGEvent, or UI.
protocol MacroEvaluating {
    /// Returns a result when `query` (the text typed after `/`, already trimmed) is a macro this
    /// family understands, or `nil` to let the next family try.
    func evaluate(_ query: String) -> MacroResult?
}

/// Splits a conversion-style query (`<value><from> <sep> <to>`) on the first separator Cotabby
/// accepts: `->`, the arrow `→`, or a space-delimited `to`. This lets `10km->mi`, `10km→mi`, and
/// `10 km to mi` all parse identically. Shared by the unit and currency evaluators so they accept the
/// same separators. Returns the (still untrimmed) left and right sides, or nil when there is no
/// separator.
enum ConversionSeparator {
    static func split(_ query: String) -> (left: String, right: String)? {
        for token in ["->", "→"] where query.contains(token) {
            if let range = query.range(of: token) {
                return (String(query[..<range.lowerBound]), String(query[range.upperBound...]))
            }
        }
        if let range = query.range(of: " to ", options: [.caseInsensitive]) {
            return (String(query[..<range.lowerBound]), String(query[range.upperBound...]))
        }
        return nil
    }
}
