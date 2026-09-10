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
///     position on the line;
///   - an observation extends the running sample only when it is on the same line (a wrap or a new
///     paragraph moves the caret to another y), the caret did not move backward, the document
///     caret grew by a keystroke's worth (`maximumStep`) and the text before the new characters
///     still ends the way it did (a window that slid, a backspace or a pasted block all fail this
///     and start over); a poll that saw no change at all (most polls) changes nothing;
///   - the sample offered ends on a letter: a space typed at the end of a line may hang with no
///     advance until the next letter arrives (its width then comes with that letter), and a
///     sample cut on the space would be a space short, a fifth of a short sample; the sample is
///     offered once it holds `minimumLength` characters;
///   - the sample is trimmed to its newest `maximumLength` characters by whole chunks, so an
///     early integer-rounded caret position weighs less as the evidence grows.
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

    /// The current sample, or nil until enough same-line typing has been seen. Chunks that end in
    /// whitespace are left off its end (their advance may still be pending), never off its front.
    var sample: Sample? {
        let usable = chunks.reversed().drop(while: { $0.text.last?.isWhitespace == true }).reversed()
        let text = usable.map(\.text).joined()
        guard text.count >= Self.minimumLength else { return nil }
        return Sample(text: text, width: usable.reduce(0) { $0 + $1.width })
    }

    /// Feeds one poll. Returns the sample after it, for callers that merge it into metrics.
    @discardableResult
    mutating func observe(_ observation: Observation) -> Sample? {
        defer { last = observation }
        guard observation.isPositioned, let previous = last, previous.isPositioned else {
            chunks.removeAll()
            return nil
        }
        let step = observation.documentCaret - previous.documentCaret
        let advance = observation.caretX - previous.caretX
        if step == 0 {
            // Nothing typed since the last poll: the field is unchanged and so is the sample. Any
            // other zero-step change (a character replaced in place) is not typing.
            guard observation.precedingText == previous.precedingText, abs(advance) < 0.01 else {
                chunks.removeAll()
                return nil
            }
            return sample
        }
        let typed = String(observation.precedingText.suffix(max(step, 0)))
        guard step >= 1, step <= Self.maximumStep,
              abs(observation.lineY - previous.lineY) <= Self.lineTolerance,
              advance >= 0,
              typed.count == step,
              !typed.contains(where: \.isNewline),
              Self.continues(previous.precedingText, into: observation.precedingText, typed: typed)
        else {
            chunks.removeAll()
            return nil
        }
        // A zero advance is a space hanging at the line's end, or a caret box the host has not
        // moved yet; either way the next letter's advance carries it.
        chunks.append(Sample(text: typed, width: advance))
        while chunks.count > 1, chunks.map(\.text.count).reduce(0, +) > Self.maximumLength {
            chunks.removeFirst()
        }
        return sample
    }

    /// Whether `next` is `previous` plus `typed`, judged on their tails so a text window that slid
    /// forward by the same characters still passes and any other change (a backspace, a paste over
    /// a selection, a moved caret) fails.
    private static func continues(_ previous: String, into next: String, typed: String) -> Bool {
        let before = next.dropLast(typed.count)
        let tail = previous.suffix(continuityLength)
        return before.hasSuffix(tail)
    }
}
