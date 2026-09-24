import Foundation

/// File overview:
/// Rules for text a host holds uncommitted ("marked") in the focused field.
///
/// Two hosts-side features produce marked text. macOS inline predictive text (Sonoma and later,
/// on by default) shows the system's own gray completion right after the caret in every
/// NSTextView: TextEdit, Notes, Mail, Messages. Input methods compose text before the caret. Both
/// spans are reported in `AXValue` like committed text, with the selection sitting at the caret,
/// so a naive reader sees "text after the caret changed" and drops the live suggestion, then a
/// regeneration paints a second gray completion over the system's one (measured live in TextEdit:
/// typing "ju" made the host show "mps", Cotabby invalidated its own " jumps over" tail, and the
/// re-shown card landed on top of the host prediction).
///
/// The policy is to treat the marked span as the host's: it is not part of the committed text
/// Cotabby reasons about, and while it is on screen Cotabby stays out of the way.
///
/// Web hosts draw their own predictions into the page instead, where no marked range names them:
/// Chromium's address bar selects its completion (see `FocusSnapshotResolver`), and Gmail writes
/// its Smart Compose suggestion into the compose body (`smartComposeSuggestionRange`).
enum HostMarkedTextPolicy {
    /// Accessibility attribute NSTextView-backed fields vend for their marked range.
    static let markedRangeAttribute = "AXTextInputMarkedRange"

    /// The key hint Gmail shows on its own line after a Smart Compose suggestion.
    static let smartComposeHint = "tab"
    /// Longest Smart Compose suggestion taken for one: Gmail suggests a few words, never a paragraph.
    static let maximumSmartComposeLength = 160

    /// The span of Gmail's Smart Compose suggestion after the caret, or nil. Gmail writes its gray
    /// suggestion and a "tab" key hint on the line below it into the editable text, so
    /// Accessibility reads both as text after the caret: in a Gmail compose body (2026-09-11) it
    /// read "lot of time\ntab", " and running\ntab", and "the app\ntab" then "he app\ntab" once its
    /// "t" was typed. Read as the user's own text, it made every caret at a line's end look mid-line: the
    /// ghost gave way to the card, and Cotabby's suggestion competed with Gmail's for the same spot
    /// and the same Tab key. The span runs from the caret through the hint; anything after that
    /// line (a signature) stays the user's. Only on Gmail, where the shape was measured, and only
    /// after a collapsed caret, with a suggestion on the caret's line and the hint alone on the next.
    static func smartComposeSuggestionRange(text: String, selection: NSRange, urlString: String?) -> NSRange? {
        guard selection.length == 0, let urlString, URLComponents(string: urlString)?.host == "mail.google.com" else {
            return nil
        }
        let nsText = text as NSString
        guard selection.location >= 0, selection.location < nsText.length else { return nil }
        let after = nsText.substring(from: selection.location) as NSString
        let lineBreak = after.range(of: "\n")
        guard lineBreak.location != NSNotFound, lineBreak.location > 0, lineBreak.location <= maximumSmartComposeLength else {
            return nil
        }
        let hint = smartComposeHint as NSString
        let hintStart = lineBreak.location + 1
        let hintEnd = hintStart + hint.length
        guard after.length >= hintEnd,
              after.substring(with: NSRange(location: hintStart, length: hint.length)) == smartComposeHint,
              hintEnd == after.length || after.substring(with: NSRange(location: hintEnd, length: 1)) == "\n"
        else {
            return nil
        }
        return NSRange(location: selection.location, length: hintEnd)
    }

    /// Removes a marked span that starts at or after the caret (the inline prediction case) from
    /// `text`, so the trailing text reflects what the user actually has. `selection` and
    /// `markedRange` are both in `text`'s coordinates. Marked text before or across the caret (an
    /// IME composition) is left in place: it belongs to the preceding text the user is still typing.
    static func strippingPredictionAfterCaret(text: String, selection: NSRange, markedRange: NSRange) -> String {
        let nsText = text as NSString
        let caretEnd = selection.location + selection.length
        guard markedRange.length > 0,
              markedRange.location >= caretEnd,
              markedRange.location < nsText.length
        else {
            return text
        }
        let clampedLength = min(markedRange.length, nsText.length - markedRange.location)
        return nsText.replacingCharacters(
            in: NSRange(location: markedRange.location, length: clampedLength),
            with: ""
        )
    }
}
