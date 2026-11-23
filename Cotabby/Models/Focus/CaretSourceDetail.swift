import Foundation

/// How the geometry resolver placed a caret rect: which host answer it took, or which mapping it
/// fell back to.
///
/// Two decisions downstream depend on it (whether the text-marker line probe may run, and whether
/// the caret's movement may be sampled as a rendered width), so it is a closed set rather than a
/// free-form label: a misspelled string would silently pick the other geometry path.
///
/// The raw values are what the debug caret badge and the structured logs show inside
/// `FocusedInputSnapshot.caretSource`, so they are kept stable.
nonisolated enum CaretSourceDetail: String, Equatable, Sendable, CaseIterable {
    /// The trailing edge of the character before the caret, from `AXBoundsForRange`.
    case previousCharacter = "previous-character"
    /// The host's own selection marker range, from `AXBoundsForTextMarkerRange`.
    case textMarker = "text-marker"
    /// A zero-length `AXBoundsForRange` answer, taken as given.
    case zeroLength = "zero-length"
    /// A zero-length answer moved onto the line box the host's line queries report.
    case zeroLengthWithLine = "zero-length+line"
    /// A zero-length answer after a trailing line break, where the host reports the previous line.
    case zeroLengthAfterBreak = "zero-length-after-break"
    /// A whole-field fallback for a wrapped static-text run whose frame spans several lines.
    case wrappedRun = "wrapped-run"
    /// The previous character's bounds inside such a wrapped run.
    case wrappedRunCharacterBounds = "wrapped-run-character-bounds"
    /// Placed inside a static-text run, every run anchored in the parent value.
    case runsAligned = "runs-aligned"
    /// Placed inside a static-text run, some runs skipped because they could not be anchored.
    case runsPartiallyAligned = "runs-partial"
    /// Placed inside a static-text run by the cumulative-length walk, no run anchored.
    case runsLegacyCumulative = "runs-legacy"

    /// Whether the caret was placed inside a text run by its share of the run's characters rather
    /// than at a measured glyph edge. Such a caret's movement is the run frame's width spread
    /// evenly over the characters, not the host's rendered advance.
    var isRunProportional: Bool {
        switch self {
        case .runsAligned, .runsPartiallyAligned, .runsLegacyCumulative:
            return true
        case .previousCharacter, .textMarker, .zeroLength, .zeroLengthWithLine, .zeroLengthAfterBreak,
             .wrappedRun, .wrappedRunCharacterBounds:
            return false
        }
    }
}
