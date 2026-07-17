import Foundation

/// File overview:
/// Pure rule deciding whether the active keyboard input source is a *composing* input method, one
/// that assembles characters from several keystrokes through provisional "marked" text (Japanese
/// kana, Chinese pinyin/zhuyin/cangjie, Korean hangul, Vietnamese Telex, ...). It is intentionally
/// free of Carbon/TIS so it stays trivially testable; `KeyboardInputSourceMonitor` reads the live
/// input source and feeds the already-extracted fields in here.
///
/// Why this matters: Cotabby commits an accepted suggestion by synthesizing a Unicode keystroke
/// (a key event on virtualKey 0). With a composing IME active, that synthetic keystroke does not
/// land as literal text, the input method re-absorbs it into composition, so the accepted text never
/// arrives, the session desyncs against the live field, and the suggestion regenerates instead of
/// committing. When this rule reports a composing mode, the inserter switches to an IME-safe path
/// (Accessibility write / clipboard paste) that bypasses the input method entirely.
enum CompositionInputModeClassifier {
    /// Input mode IDs an IME exposes for typing plain ASCII *directly* (committed per keystroke, no
    /// marked text), where the normal keystroke insertion is fine. The system Japanese IMEs share
    /// `com.apple.inputmethod.Roman` for their alphanumeric ("英数") mode.
    static let nonComposingInputModeIDs: Set<String> = [
        "com.apple.inputmethod.Roman"
    ]

    /// Whether the current input source composes through marked text (so committing accepted text
    /// needs the IME-safe insertion path).
    ///
    /// - Parameters:
    ///   - isKeyboardLayout: the TIS source type is a plain keyboard layout (U.S., Dvorak, British,
    ///     ...). Layouts commit every keystroke directly and never compose.
    ///   - inputModeID: `kTISPropertyInputModeID` of the active source when it is an input mode; nil
    ///     for plain layouts and some method-without-modes IMEs.
    ///
    /// A plain layout never composes. Any non-layout input *method/mode* is treated as composing,
    /// except the shared direct-ASCII mode. Erring toward "composing for any unrecognized non-layout
    /// source" is the safe default: a third-party or future IME (ATOK, Sogou, ...) is far likelier to
    /// compose through marked text than to commit plain ASCII, and the cost of a false positive is
    /// only that we route through the (also-correct) IME-safe insertion path, whereas a false
    /// negative reproduces the can't-accept bug.
    static func isComposingInputMode(isKeyboardLayout: Bool, inputModeID: String?) -> Bool {
        if isKeyboardLayout {
            return false
        }
        if let inputModeID, nonComposingInputModeIDs.contains(inputModeID) {
            return false
        }
        return true
    }
}
