import CoreGraphics

/// File overview:
/// Everything the emoji picker knows about one open `:query` capture. The controller holds this as
/// an optional: `nil` is idle, a value is capturing. Keeping the fields in one value means they are
/// created together when a capture opens and dropped together when it ends, so no combination like
/// "matches without a caret anchor" or "a focus sequence with no capture" can exist.
///
/// The trigger machine still owns the keystroke-level lifecycle; this is the payload that depends
/// on Accessibility (where the capture lives) and on the matcher (what it is showing).
struct EmojiCaptureSession: Equatable {
    /// The focus sequence of the field the capture opened in. A snapshot carrying a different value
    /// means the typed `:query` run is no longer under the caret.
    let focusChangeSequence: UInt64
    /// Latest caret position, which the panel follows as the query grows.
    var caretRect: CGRect
    private(set) var query = ""
    private(set) var matches: [EmojiMatch] = []
    private(set) var selectedIndex = 0

    init(focusChangeSequence: UInt64, caretRect: CGRect) {
        self.focusChangeSequence = focusChangeSequence
        self.caretRect = caretRect
    }

    /// The highlighted match, or `nil` when there is nothing to commit.
    var selectedMatch: EmojiMatch? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
    }

    /// Replaces the ranked results for a new query. The highlight returns to the best match because
    /// an index into the old ranking means nothing in the new one.
    mutating func setResults(_ matches: [EmojiMatch], for query: String) {
        self.query = query
        self.matches = matches
        selectedIndex = 0
    }

    /// Moves the highlight one step, wrapping at either end of the ribbon. Returns `false` (and
    /// changes nothing) when there are no matches to move through.
    mutating func moveSelection(_ move: EmojiSelectionMove) -> Bool {
        guard !matches.isEmpty else {
            return false
        }
        switch move {
        case .previous:
            selectedIndex = (selectedIndex - 1 + matches.count) % matches.count
        case .next:
            selectedIndex = (selectedIndex + 1) % matches.count
        }
        return true
    }

    /// Points the highlight at a clicked cell. An out-of-range index is kept as given, which makes
    /// `selectedMatch` nil so the commit that follows inserts nothing.
    mutating func select(index: Int) {
        selectedIndex = index
    }
}
