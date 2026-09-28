import Foundation

/// File overview:
/// Where the caret sits relative to the token around it. Generation only makes sense at a token
/// end: a caret strictly inside a word, number, identifier or address ("head|phones", "3|:30",
/// "jane|@example.com", "items.red|uce") already has its continuation on the right, and every
/// completion the model offers there is a duplicate of what follows or a splice into the middle of
/// something. The eval's dup-trailing cases were exactly this shape, and all of them showed.
enum CaretTokenPosition {
    /// Characters that glue a token together when a word character follows them: the caret in
    /// "3|:30", "jane|@example", "www|.example", "snake|_case", "kebab|-case", "a|/b".
    private static let tokenJoiners: Set<Character> = [":", "@", ".", "/", "-", "_", "'", "’"]

    static func isInsideToken(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else {
            return false
        }
        guard let after = trailingText.first else {
            return false
        }
        if isWordCharacter(after) {
            return true
        }
        if tokenJoiners.contains(after) {
            let rest = trailingText.dropFirst()
            if let next = rest.first, isWordCharacter(next) {
                return true
            }
        }
        return false
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
