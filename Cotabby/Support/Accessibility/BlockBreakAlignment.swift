import Foundation

/// File overview:
/// Maps a caret from a Chromium field's range text into its value, where the two disagree about
/// the breaks between blocks.
///
/// A Chromium contenteditable reads out in two coordinate spaces. Its `AXValue` puts a line break
/// between block elements (paragraphs, list items). Its range queries (`AXSelectedTextRange`,
/// `AXStringForRange`) and its text-marker strings run the blocks together, and the caret offset
/// is counted in that run-together space. A break typed with Shift+Return is a character in both.
/// Measured 2026-09-11 in a ProseMirror replica of Claude's composer: the value "abc\ndef\nghi"
/// against the range text "abc\ndefghi", the caret at the end reported at 10 of the value's 11.
/// Read in the range space:
///   - the model was handed "here.Se" and continued it as "conde paragraph";
///   - the caret line's text for the pixel match ran back through the paragraphs before it;
///   - the text after the caret came back empty: a window sized from `AXNumberOfCharacters` (the
///     value's length) asks past the range text's end and Chrome answers nil, so a caret in the
///     middle of earlier text read as the end of its line and got an inline ghost over the host's
///     own words.
///
/// Two spots share one range offset: the end of a block and the start of the next ("here.|" and
/// "|Second" are both 26). In the value they sit on either side of the break, and only the host
/// knows which one the caret is at, so the caller answers that (`AXHelper.caretStartsTextBlock`),
/// and is asked only when a break follows the aligned caret.
///
/// Pure and in `Support/` so the alignment, the part of this that is easy to get subtly wrong, is
/// tested without a live Accessibility tree. `FocusSnapshotResolver` owns the one call site.
nonisolated enum BlockBreakAlignment {
    /// The value's text with the selection in its UTF-16 offsets.
    struct Split: Equatable, Sendable {
        let text: String
        let selection: NSRange
    }

    private static let lineFeed: UInt16 = 0x0A

    /// The value offset (UTF-16) just after `rangePrefix`, the range text from the field's start to
    /// the caret, when that text is the value's start with only line breaks left out; nil when the
    /// two differ in anything else. A left-out break is skipped only to match the next character,
    /// so the offset is the earliest spot: before a break that follows.
    static func valueOffset(following rangePrefix: String, in value: String) -> Int? {
        match(rangePrefix.utf16, in: Array(value.utf16), from: 0)?.end
    }

    /// The value split at the range text's selection, or nil when the texts do not align (the
    /// caller then keeps the range text). `caretStartsBlock` is asked only for an empty selection
    /// with a break right after it: true puts the caret after that break, at the next block's start.
    static func split(
        value: String,
        rangePrefix: String,
        rangeSelected: String,
        caretStartsBlock: () -> Bool
    ) -> Split? {
        let units = Array(value.utf16)
        guard let prefix = match(rangePrefix.utf16, in: units, from: 0) else { return nil }
        guard !rangeSelected.isEmpty else {
            var caret = prefix.end
            if caret < units.count, units[caret] == lineFeed, caretStartsBlock() {
                caret += 1
            }
            return Split(text: value, selection: NSRange(location: caret, length: 0))
        }
        // A selection starts at its first character, after any break left out before it.
        guard let selected = match(rangeSelected.utf16, in: units, from: prefix.end) else { return nil }
        return Split(text: value, selection: NSRange(location: selected.first, length: selected.end - selected.first))
    }

    /// Walks `units` through the value from `start`, skipping only the line breaks the range text
    /// left out. Returns where the first unit matched and the offset after the last, or nil at the
    /// first unit that differs.
    private static func match(_ units: String.UTF16View, in value: [UInt16], from start: Int) -> (first: Int, end: Int)? {
        var index = start
        var first: Int?
        for unit in units {
            while index < value.count, value[index] != unit, value[index] == lineFeed {
                index += 1
            }
            guard index < value.count, value[index] == unit else { return nil }
            if first == nil { first = index }
            index += 1
        }
        return (first ?? index, index)
    }
}
