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
enum HostMarkedTextPolicy {
    /// Accessibility attribute NSTextView-backed fields vend for their marked range.
    static let markedRangeAttribute = "AXTextInputMarkedRange"

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
