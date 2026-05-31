import Foundation

/// File overview:
/// Decides whether the first generated token should be constrained to continue the current word.
///
/// Why this file exists:
/// The engine can force the first sampled token to be a word continuation (no leading whitespace),
/// which heals mid-word completions. But forcing it at a normal word boundary would break the
/// common "predict the next word" case, where a leading space is exactly what we want. This policy
/// keeps the trigger deliberately narrow: it only fires when the caret sits strictly inside a word
/// (a word character on both sides). At a word end (nothing or a non-word character after the
/// caret) it returns false so ordinary next-word predictions are untouched.
enum MidWordContinuationPolicy {
    static func shouldForceContinuation(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else {
            return false
        }
        guard let after = trailingText.first, isWordCharacter(after) else {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
