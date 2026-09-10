import CoreGraphics
import Foundation

/// File overview:
/// Measures how wide the host really renders its text by watching the caret move as the user
/// types: between two focus polls on the same line, the characters that arrived and the distance
/// the caret travelled are one width sample of the host's own glyphs.
///
/// Why this exists: `HostTextMetricsProbe` asks the host for the rendered width of the text before
/// the caret, and a Chromium contenteditable answers nothing. The only size such a host reports is
/// the CSS font size, which knows nothing about page or Electron zoom: the Claude desktop composer
/// reported 14 while painting its face at 15.4 (110% zoom, measured 2026-09-10 from the caret's
/// own movement, `hostadv.py`), so the ghost was drawn a tenth too small, its typed-through pens
/// drifted off the host's caret, the leading space visibly collapsed, and the tail left after an
/// accepted word landed on the inserted text. The caret is the one width the host cannot misreport:
/// after "the " it sits exactly one "the " further right, in the host's real face at the host's
/// real size. `GhostFontResolver` scales its stand-in face to this sample exactly as it would to
/// the probe's, so the ghost's advances match the host's whatever the reported size says.
///
/// Rules, all measured against Chromium's behavior:
///   - only an exact or derived caret counts; an estimated one is a guess about the field, not a
///     position on the line, and is simply skipped: CodeMirror's polls alternate between a
///     run-aligned caret and an estimated one (Obsidian, 2026-09-10), and resetting on every
///     estimated poll left the field without a sample for good;
///   - an observation extends the running sample only when it is on the same line (a wrap or a new
///     paragraph moves the caret to another y), the caret did not move backward, the document
///     caret grew by a keystroke's worth (`maximumStep`) and the text before the new characters
///     still ends the way it did (a window that slid, a backspace or a pasted block all fail this
///     and start over); a poll that saw no change at all (most polls) changes nothing;
///   - a character whose poll shows no caret movement is held back until the caret moves: a
///     space typed at the end of a line hangs with no advance until the next letter, and a host
///     can publish a keystroke's text a poll before its caret box (measured in Chrome's
///     contenteditable, 2026-09-10: the first twelve-character sample was one advance short,
///     eight percent, and the ghost rendered at 13.7 for a 15px field); the held text joins the
///     next chunk whose advance covers it, so text and width always describe the same glyphs;
///   - the other order holds too: a caret box that moves before its keystroke's text is published
///     keeps that movement for the text that follows, once. Reading it as an edit started the
///     sample over with the character still to come, which then took the next character's
///     advance: every chunk paid one character late, and the sample held one more character than
///     its width covered (Chrome's contenteditable, 2026-09-10: "i Sarah, thanks for s" measured
///     131.0 for 135.3, which read as a face 3% narrow and briefly matched Avenir Next);
///     the sample is offered once it holds `minimumLength` characters;
///   - the sample is trimmed to its newest `maximumLength` characters by whole chunks, so an
///     early integer-rounded caret position weighs less as the evidence grows;
///   - a non-breaking space reads as a space: Chromium stores a space typed at the end of a line
///     as U+00A0 and turns it into U+0020 once the next character arrives, which would otherwise
///     break the text's continuity at every word (measured 2026-09-10: no sample ever formed in a
///     Chrome contenteditable, 389 presentations without one).
///
/// Pure value type in `Support/`: the resolver keeps one per focused field and feeds it every poll;
/// nothing here touches Accessibility.
nonisolated struct CaretAdvanceSampler: Equatable, Sendable {
    /// One focus poll's view of the caret.
    struct Observation: Equatable, Sendable {
        /// Leading x of the caret box in global Cocoa points.
        let caretX: CGFloat
        /// Top of the caret box; same-line observations share it within `lineTolerance`.
        let lineY: CGFloat
        /// The caret's offset in the host's own document, so a slid text window cannot masquerade
        /// as typing.
        let documentCaret: Int
        /// The text before the caret as the snapshot carries it (possibly a bounded tail).
        let precedingText: String
        /// True for `.exact` and `.derived` caret geometry.
        let isPositioned: Bool
    }

    struct Sample: Equatable, Sendable {
        /// The characters the caret travelled across, oldest first.
        let text: String
        /// How far the caret travelled across them, in points.
        let width: CGFloat
    }

    /// Characters a sample needs before it is worth scaling a face to: Chromium rounds caret boxes
    /// to whole pixels, so a sample this long carries at most about a percent of rounding.
    static let minimumLength = 12
    /// Newest characters kept; older chunks fall off the front.
    static let maximumLength = 32
    /// Most characters one poll may add before the change is not typing (a paste, an autocorrect).
    static let maximumStep = 8
    /// Vertical slack between two carets on one line (web engines round line tops to pixels).
    static let lineTolerance: CGFloat = 1.5
    /// Characters of the previous text that must still precede the new ones.
    private static let continuityLength = 24

    private var last: Observation?
    private var chunks: [Sample] = []
    /// Characters typed whose advance the caret has not shown yet (see the file overview).
    private var pendingText = ""
    /// Caret movement seen before the text it belongs to (see the file overview); at most one
    /// poll's worth, claimed by the next text that arrives.
    private var unclaimedAdvance: CGFloat = 0

    /// The current sample, or nil until enough same-line typing has been seen. Chunks that end in
    /// whitespace are left off its end (their advance may still be pending), never off its front.
    var sample: Sample? {
        let usable = chunks.reversed().drop(while: { $0.text.last?.isWhitespace == true }).reversed()
        let text = usable.map(\.text).joined()
        guard text.count >= Self.minimumLength else { return nil }
        return Sample(text: text, width: usable.reduce(0) { $0 + $1.width })
    }

    /// Characters typed so far that no chunk accounts for yet, for diagnostics.
    var pendingCharacterCount: Int { pendingText.count }

    /// Feeds one poll. Returns the sample after it, for callers that merge it into metrics.
    @discardableResult
    mutating func observe(_ observation: Observation) -> Sample? {
        guard observation.isPositioned else { return sample }
        defer { last = observation }
        guard let previous = last else {
            startOver()
            return nil
        }
        let step = observation.documentCaret - previous.documentCaret
        let advance = observation.caretX - previous.caretX
        if step == 0 {
            // Nothing typed since the last poll: the field is unchanged and so is the sample. Any
            // other zero-step change (a character replaced in place) is not typing.
            guard Self.spaceNormalized(observation.precedingText) == Self.spaceNormalized(previous.precedingText)
            else {
                startOver()
                return nil
            }
            // The caret caught up with text already counted: its advance belongs to that text.
            if advance > 0, !pendingText.isEmpty {
                chunks.append(Sample(text: pendingText, width: advance))
                pendingText = ""
                return sample
            }
            // The caret moved ahead of its text: the text that arrives next claims the movement.
            // A second such move before any text is not the host's lag; start over.
            if advance > 0, unclaimedAdvance == 0 {
                unclaimedAdvance = advance
                return sample
            }
            guard abs(advance) < 0.01 else {
                startOver()
                return nil
            }
            return sample
        }
        let next = Self.spaceNormalized(observation.precedingText)
        let typed = String(next.suffix(max(step, 0)))
        guard step >= 1, step <= Self.maximumStep,
              abs(observation.lineY - previous.lineY) <= Self.lineTolerance,
              advance >= 0,
              typed.count == step,
              !typed.contains(where: \.isNewline),
              Self.continues(Self.spaceNormalized(previous.precedingText), into: next, typed: typed)
        else {
            startOver()
            return nil
        }
        // A caret that moved ahead of this text already showed (part of) its advance.
        let travelled = advance + unclaimedAdvance
        unclaimedAdvance = 0
        // A zero advance is a space hanging at the line's end, or a caret box the host has not
        // moved yet; either way the next movement carries it, so the text waits for it.
        guard travelled > 0 else {
            pendingText += typed
            return sample
        }
        chunks.append(Sample(text: pendingText + typed, width: travelled))
        pendingText = ""
        while chunks.count > 1, chunks.map(\.text.count).reduce(0, +) > Self.maximumLength {
            chunks.removeFirst()
        }
        return sample
    }

    private mutating func startOver() {
        chunks.removeAll()
        pendingText = ""
        unclaimedAdvance = 0
    }

    /// Whether `next` is `previous` plus `typed`, judged on their tails so a text window that slid
    /// forward by the same characters still passes and any other change (a backspace, a paste over
    /// a selection, a moved caret) fails.
    private static func continues(_ previous: String, into next: String, typed: String) -> Bool {
        let before = next.dropLast(typed.count)
        let tail = previous.suffix(continuityLength)
        return before.hasSuffix(tail)
    }

    /// Text with every non-breaking space read as a plain space (one UTF-16 unit each, so offsets
    /// are unchanged); see `SuggestionSessionReconciler.spaceNormalized`.
    private static func spaceNormalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
