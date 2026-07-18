import Foundation

/// A selection synthesized for a Chromium/WebKit `contenteditable` from its opaque text markers.
///
/// `text` is windowed around the caret (not the full document) so a long Gmail thread does not
/// bloat every focus snapshot, and `selection` is expressed as an `NSRange` into that windowed
/// `text` (not a document offset). Keeping the two consistent is the whole point: the rest of the
/// pipeline treats `text` + `selection` as a unit when splitting before/after-caret context.
struct MarkerSelection: Equatable {
    let text: String
    let selection: NSRange
}

/// Pure logic for turning the three text fragments around a caret (before / selected / after),
/// read from text markers in `AXHelper`, into a caret-windowed `MarkerSelection`.
///
/// This is split out from the AX I/O so the windowing and offset arithmetic can be unit-tested
/// without a live Accessibility tree.
enum MarkerSelectionSynthesizer {
    /// Default half-window, in UTF-16 units, kept on each side of the caret.
    static let defaultWindow = 4096

    /// Builds a caret-windowed selection from the document text on either side of the caret.
    ///
    /// The location is derived from the UTF-16 length of the (windowed) before-caret text rather
    /// than from `AXLengthForTextMarkerRange`: deriving it from the same string we expose as
    /// `text` sidesteps any unit mismatch (character vs. UTF-16 vs. byte) between the marker-length
    /// API and the `NSRange`/`NSString` indexing the rest of the pipeline uses.
    static func make(
        beforeCaret: String,
        selected: String,
        afterCaret: String,
        window: Int = defaultWindow
    ) -> MarkerSelection {
        let windowedBefore = suffix(of: beforeCaret, limit: window)
        let windowedAfter = prefix(of: afterCaret, limit: window)
        let text = windowedBefore + selected + windowedAfter

        let location = (windowedBefore as NSString).length
        let length = (selected as NSString).length

        return MarkerSelection(text: text, selection: NSRange(location: location, length: length))
    }

    /// Trailing window measured in UTF-16 units so the kept slice lines up with `NSString` lengths.
    /// Trimming on a UTF-16 boundary could split a surrogate pair, so we widen to the nearest
    /// `Character` boundary that keeps the slice within the limit.
    private static func suffix(of string: String, limit: Int) -> String {
        let ns = string as NSString
        guard ns.length > limit else { return string }
        let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: ns.length - limit, length: limit))
        return ns.substring(with: range)
    }

    private static func prefix(of string: String, limit: Int) -> String {
        let ns = string as NSString
        guard ns.length > limit else { return string }
        let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: limit))
        return ns.substring(with: range)
    }
}
