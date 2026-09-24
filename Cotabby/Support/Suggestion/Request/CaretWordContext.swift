import Foundation

/// A lexical snapshot of the caret, shared by correction and completion policy.
/// A pause carries no evidence that a word is finished. Only a delimiter commits a word;
/// the coordinator supplies text, and this value owns no editor, spell checker, or tasks.
nonisolated enum CaretWordContext {
    struct CommittedWord: Equatable {
        let word: String
        let delimiter: String
    }

    /// Apostrophes and hyphens remain inside words; code-like tokens and scripts without
    /// space-delimited words are left to their existing completion paths.
    static func unfinishedWord(in text: String) -> String? {
        let token = String(text.reversed().prefix(while: { !$0.isWhitespace }).reversed())
        // An opening quote or parenthesis frames prose; it does not finish the word being typed.
        // Strip only leading prose openers so `(wor` shares the normal mid-word timing and seam
        // checks, while embedded punctuation in `call(wor`, URLs, and identifiers stays excluded.
        let word = token.drop(while: { "(\"'“‘«‹".contains($0) })
        guard !word.isEmpty, word.first?.isLetter == true,
              word.allSatisfy({ $0.isLetter || isConnector($0) }),
              !word.unicodeScalars.contains(where: isUnspacedScript) else { return nil }
        return String(word)
    }

    /// Deliberately bounded: after another whitespace character the writer has moved on.
    /// Sentence punctuation is preserved verbatim by the replacement planner. A period is
    /// excluded here because a dotted identifier or URL is indistinguishable at this boundary.
    static func committedWord(in text: String) -> CommittedWord? {
        var body = text
        var delimiter = ""
        if body.last == " " {
            body.removeLast()
            delimiter = " "
        }
        if let last = body.last, ",;:!?".contains(last) {
            body.removeLast()
            delimiter = String(last) + delimiter
        }
        guard !delimiter.isEmpty, let word = CurrentWordExtractor.extract(from: body)?.word,
              unfinishedWord(in: body) == word else { return nil }
        return CommittedWord(word: word, delimiter: delimiter)
    }

    static func isConnector(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "-"
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0x20000...0x3134F:
            return true
        default: return false
        }
    }
}
