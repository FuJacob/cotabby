import AppKit
import Foundation

/// File overview:
/// Provides a fast local completion path for the word currently being typed.
///
/// Why this exists:
/// A chat/instruct LLM is the wrong tool for the most common autocomplete operation: finishing a
/// partially typed word. macOS already has an on-device spelling/completion engine that can answer
/// this case without prompting, sampling, OCR context, or network access. This provider lets Tabby
/// behave more like system autocomplete for `minu` -> `tes` while keeping the slower llama path for
/// phrase-level continuation.
@MainActor
enum LocalWordCompletionProvider {
    /// Attempts a deterministic word completion for the live caret context.
    ///
    /// Returns `nil` when the caret is not inside a normal word or when macOS does not have a useful
    /// candidate. `SuggestionCoordinator` then falls through to the configured model engine.
    static func suggestion(for context: FocusedInputContext) -> SuggestionResult? {
        let startTime = Date()

        guard context.selection.length == 0,
              context.trailingText.first?.isLetterOrNumber != true,
              let currentToken = LocalWordCompletionCandidateReducer.currentToken(
                in: context.precedingText
              )
        else {
            return nil
        }

        let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        defer {
            NSSpellChecker.shared.closeSpellDocument(withTag: documentTag)
        }

        let candidateText = currentToken
        let candidateRange = NSRange(
            location: 0,
            length: (candidateText as NSString).length
        )
        let candidates = NSSpellChecker.shared.completions(
            forPartialWordRange: candidateRange,
            in: candidateText,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []

        guard let completion = LocalWordCompletionCandidateReducer.suggestionTail(
            currentToken: currentToken,
            candidates: candidates,
            precedingText: context.precedingText
        ) else {
            return nil
        }

        return SuggestionResult(
            generation: context.generation,
            rawText: "[local-word-completion] \(currentToken)\(completion)",
            text: completion,
            latency: Date().timeIntervalSince(startTime)
        )
    }
}

/// Pure candidate filtering for the local word-completion path.
///
/// Keeping the reducer separate from `NSSpellChecker` gives us deterministic unit coverage for the
/// rules that protect the overlay from duplicates, whole-word insertion, and noisy candidates.
enum LocalWordCompletionCandidateReducer {
    private static let minimumTokenLength = 3
    private static let maximumTokenLength = 24
    private static let minimumTailLength = 2

    static func currentToken(in precedingText: String) -> String? {
        guard let range = precedingText.range(
            of: #"[A-Za-z][A-Za-z'\-]{2,23}$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let token = String(precedingText[range])
        guard token.count >= minimumTokenLength,
              token.count <= maximumTokenLength
        else {
            return nil
        }

        return token
    }

    static func suggestionTail(
        currentToken: String,
        candidates: [String],
        precedingText: String = ""
    ) -> String? {
        let normalizedToken = currentToken.lowercased()
        let prefersPlural = precedingTextSuggestsPlural(
            precedingText,
            currentToken: currentToken
        )

        let viableCandidates = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { candidate in
                let normalizedCandidate = candidate.lowercased()
                return candidate.count > currentToken.count
                    && normalizedCandidate.hasPrefix(normalizedToken)
                    && candidate.range(of: #"^[A-Za-z][A-Za-z'\-]{2,31}$"#, options: .regularExpression) != nil
            }

        guard let bestCandidate = viableCandidates.min(by: { lhs, rhs in
            let lhsScore = candidateScore(
                lhs,
                currentToken: currentToken,
                prefersPlural: prefersPlural
            )
            let rhsScore = candidateScore(
                rhs,
                currentToken: currentToken,
                prefersPlural: prefersPlural
            )
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            return lhs.count < rhs.count
        }) else {
            return nil
        }

        let tailStart = bestCandidate.index(
            bestCandidate.startIndex,
            offsetBy: currentToken.count
        )
        let tail = String(bestCandidate[tailStart...])

        guard tail.count >= minimumTailLength,
              tail.count <= 16
        else {
            return nil
        }

        return tail
    }

    private static func candidateScore(
        _ candidate: String,
        currentToken: String,
        prefersPlural: Bool
    ) -> Int {
        var score = candidate.count - currentToken.count

        // Prefer ordinary word endings over very long dictionary entries. The local path is for
        // quick word finish, not phrase prediction.
        let lowercased = candidate.lowercased()
        if lowercased.hasSuffix("s") || lowercased.hasSuffix("ed") || lowercased.hasSuffix("ing") {
            score -= 1
        }
        if prefersPlural, lowercased.hasSuffix("s") {
            score -= 3
        }

        return score
    }

    private static func precedingTextSuggestsPlural(
        _ precedingText: String,
        currentToken: String
    ) -> Bool {
        let escapedToken = NSRegularExpression.escapedPattern(for: currentToken)
        let pattern = #"\b(?:0|[2-9]|\d{2,})\s+\#(escapedToken)$"#
        return precedingText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
