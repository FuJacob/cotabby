import Foundation

/// File overview:
/// Decides whether an LLM-proposed correction to the user's prefix is "typo-shaped"
/// enough to apply, or whether it has drifted into rewording, repunctuation, or
/// recapitalization that the user did not ask for.
///
/// The filter is the safety net for prefix auto-correct. Even with a tight prompt the
/// model will sometimes rephrase, change capitalization, or "improve" punctuation.
/// Those changes are silently destructive because the write replaces the user's typed
/// text without a diff UI. Only changes that look like single-word spelling fixes are
/// allowed through.
enum PrefixCorrectionFilter {
    /// Returns `proposed` when it is a safe typo-fix of `original`, or `nil` to drop it.
    ///
    /// Rules — all must hold:
    /// - Same number of word/separator tokens, in the same order.
    /// - Inter-word separators (whitespace, punctuation) are byte-identical.
    /// - For each word pair that differs:
    ///   - Both words are at least `minimumWordLength` characters.
    ///   - Case shape matches (all-lower, all-upper, capitalized, or mixed).
    ///   - Edit distance ≤ `max(2, length / 3)` using the longer of the two words.
    static func acceptedCorrection(original: String, proposed: String) -> String? {
        guard original != proposed else { return nil }

        let originalTokens = tokenize(original)
        let proposedTokens = tokenize(proposed)
        guard originalTokens.count == proposedTokens.count else { return nil }

        for (originalToken, proposedToken) in zip(originalTokens, proposedTokens) {
            switch (originalToken, proposedToken) {
            case let (.separator(originalRun), .separator(proposedRun)):
                guard originalRun == proposedRun else { return nil }
            case let (.word(originalWord), .word(proposedWord)):
                guard isTypoShapedChange(original: originalWord, proposed: proposedWord) else { return nil }
            default:
                // Boundary mismatch: a word in one stream lines up with a separator in the other.
                return nil
            }
        }

        return proposed
    }

    // MARK: - Tokenization

    private static let minimumWordLength = 3

    private enum Token: Equatable {
        case word(String)
        case separator(String)
    }

    /// Splits `text` into alternating runs of Unicode letters and everything else.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false

        for scalar in text.unicodeScalars {
            let scalarIsLetter = CharacterSet.letters.contains(scalar)
            if current.isEmpty {
                current.unicodeScalars.append(scalar)
                currentIsWord = scalarIsLetter
                continue
            }

            if scalarIsLetter == currentIsWord {
                current.unicodeScalars.append(scalar)
            } else {
                tokens.append(currentIsWord ? .word(current) : .separator(current))
                current = String(scalar)
                currentIsWord = scalarIsLetter
            }
        }

        if !current.isEmpty {
            tokens.append(currentIsWord ? .word(current) : .separator(current))
        }

        return tokens
    }

    // MARK: - Per-word shape check

    private static func isTypoShapedChange(original: String, proposed: String) -> Bool {
        if original == proposed { return true }
        guard original.count >= minimumWordLength, proposed.count >= minimumWordLength else {
            return false
        }
        guard caseShape(of: original) == caseShape(of: proposed) else { return false }
        let distance = levenshteinDistance(original.lowercased(), proposed.lowercased())
        let allowed = Swift.max(2, Swift.max(original.count, proposed.count) / 3)
        return distance <= allowed
    }

    private enum CaseShape: Equatable {
        case allLower
        case allUpper
        case capitalized
        case mixed
    }

    /// Categorizes a word by its capitalization pattern so the filter can reject changes
    /// that swap between shapes (the model "fixing" capitalization the user didn't ask for).
    private static func caseShape(of word: String) -> CaseShape {
        let letters = word.filter { $0.isLetter }
        guard let first = letters.first else { return .mixed }

        let rest = letters.dropFirst()
        let allLower = letters.allSatisfy(\.isLowercase)
        if allLower { return .allLower }
        let allUpper = letters.allSatisfy(\.isUppercase)
        if allUpper { return .allUpper }
        if first.isUppercase, rest.allSatisfy(\.isLowercase) { return .capitalized }
        return .mixed
    }

    /// Standard two-row Levenshtein. Words are short, so the simple implementation is fine.
    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let lhsLength = lhsChars.count
        let rhsLength = rhsChars.count
        if lhsLength == 0 { return rhsLength }
        if rhsLength == 0 { return lhsLength }

        var previous = Array(0...rhsLength)
        var current = Array(repeating: 0, count: rhsLength + 1)

        for row in 1...lhsLength {
            current[0] = row
            for col in 1...rhsLength {
                let cost = lhsChars[row - 1] == rhsChars[col - 1] ? 0 : 1
                current[col] = Swift.min(
                    previous[col] + 1,
                    current[col - 1] + 1,
                    previous[col - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[rhsLength]
    }
}
