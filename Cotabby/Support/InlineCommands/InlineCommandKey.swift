import CoreGraphics

/// File overview:
/// The keystroke vocabulary shared by the inline-command features (the `:emoji:` picker and the
/// `/macro` preview). Both captures must read the same physical keys the same way: which chords end
/// a capture, which key commits, and what counts as one typed query character. They differ only in
/// what an arrow means (the picker moves its selection, the macro preview closes). Classifying once
/// here keeps the two controllers from drifting apart on those shared rules.

/// The four arrow keys, kept distinct so each feature can decide what a direction means.
enum InlineCommandArrow: Equatable {
    case up
    case down
    case left
    case right
}

/// One captured key-down reduced to what an inline capture can act on.
enum InlineCommandKey: Equatable {
    /// A single printable character that reached the field.
    case character(Character)
    /// A plain one-character Backspace.
    case backspace
    /// The user's configured word-accept binding.
    case commitKey
    case escape
    case arrow(InlineCommandArrow)
    /// The field changed (or is about to) in a way a character-by-character query cannot follow,
    /// so the only safe reaction is to end the capture and let the key through.
    case dismissExternally
}

enum InlineCommandKeyClassifier {
    /// `isWordAcceptKey` is consulted before the key-code table so a rebound accept key wins over
    /// its default meaning. It is never asked about Command/Control chords: those are app
    /// shortcuts and always end a capture.
    static func classify(
        _ event: CapturedInputEvent,
        isWordAcceptKey: (InputMonitorKeyEvent) -> Bool
    ) -> InlineCommandKey {
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            return .dismissExternally
        }

        if isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            return .commitKey
        }

        if let key = nonCharacterKey(keyCode: event.keyCode, modifiers: modifiers) {
            return key
        }

        let characters = event.characters
        if characters.count == 1, let character = characters.first, !character.isNewline {
            return .character(character)
        }
        // Empty or multi-character key-downs (dead keys, IME composition) cannot extend a query.
        return .dismissExternally
    }

    /// Keys whose meaning comes from the key code rather than the characters they produce.
    private static func nonCharacterKey(
        keyCode: CGKeyCode,
        modifiers: ShortcutModifierMask
    ) -> InlineCommandKey? {
        switch keyCode {
        case 53:
            return .escape
        case 36, 76:
            // Return and Keypad Enter submit or break the line in the host; they never commit.
            return .dismissExternally
        case 126:
            return .arrow(.up)
        case 125:
            return .arrow(.down)
        case 123:
            return .arrow(.left)
        case 124:
            return .arrow(.right)
        case 117:
            // Forward Delete removes text after the caret, which the tracked query cannot see.
            return .dismissExternally
        case 51:
            // Option + Backspace deletes a whole word, which the single-character query model
            // cannot track. (Command + Backspace never gets here: the caller's modifier check
            // already dismissed it.)
            return modifiers.contains(.option) ? .dismissExternally : .backspace
        default:
            return nil
        }
    }
}
