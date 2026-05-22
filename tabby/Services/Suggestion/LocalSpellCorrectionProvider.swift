import AppKit
import Foundation

/// File overview:
/// Provides a fast, local spell-correction path before Tabby asks a generative model for context.
///
/// Why this file is its own boundary:
/// Spell correction is not prompt construction and it is not model generation. It is a deterministic
/// AppKit service lookup plus a pure reducer that decides whether the result is safe enough to show.
/// Keeping it next to `LocalWordCompletionProvider` makes the local-first path explicit while keeping
/// `SuggestionCoordinator` focused on orchestration.
@MainActor
enum LocalSpellCorrectionProvider {
    /// Attempts a one-shot correction for the current token or the just-finished token before it.
    ///
    /// The focused context is read exactly as Accessibility reported it. We do not mutate the prompt
    /// context because the normal model path must still see the real field if correction confidence is
    /// low and this provider falls through.
    static func suggestion(for context: FocusedInputContext) -> SuggestionResult? {
        let startTime = Date()

        guard context.selection.length == 0,
              context.trailingText.first?.isLetterOrNumber != true,
              let target = LocalSpellCorrectionCandidateReducer.correctionTarget(
                in: context.precedingText
              )
        else {
            return nil
        }

        let documentTag = NSSpellChecker.uniqueSpellDocumentTag()
        defer {
            NSSpellChecker.shared.closeSpellDocument(withTag: documentTag)
        }

        let tokenRange = NSRange(location: 0, length: (target.token as NSString).length)
        let misspelledRange = NSSpellChecker.shared.checkSpelling(
            of: target.token,
            startingAt: 0,
            language: nil,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        guard misspelledRange.location != NSNotFound else {
            return nil
        }

        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: tokenRange,
            in: target.token,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []

        guard let correction = LocalSpellCorrectionCandidateReducer.correctedText(
            for: target,
            candidates: guesses
        ) else {
            return nil
        }

        return SuggestionResult(
            generation: context.generation,
            rawText: "[local-spell-correction] \(target.token) -> \(correction)",
            text: correction,
            latency: Date().timeIntervalSince(startTime),
            acceptanceEdit: .replacePreviousCharacters(count: target.replacedCharacterCount)
        )
    }
}

/// Pure filtering for local spell correction.
///
/// `NSSpellChecker` can return broad guesses, including style variants and completions. This reducer
/// keeps only small whole-token corrections so Tabby does not preempt a context suggestion unless the
/// replacement is likely to be what the user meant.
enum LocalSpellCorrectionCandidateReducer {
    struct CorrectionTarget: Equatable {
        let token: String
        let trailingDelimiter: String
        let replacedCharacterCount: Int
    }

    private static let tokenPattern = #"[A-Za-z][A-Za-z'\-]{2,23}"#
    private static let tokenRegex = #"^\#(tokenPattern)$"#

    static func correctionTarget(in precedingText: String) -> CorrectionTarget? {
        if let currentRange = precedingText.range(
            of: #"\#(tokenPattern)$"#,
            options: .regularExpression
        ) {
            let token = String(precedingText[currentRange])
            return CorrectionTarget(
                token: token,
                trailingDelimiter: "",
                replacedCharacterCount: token.count
            )
        }

        guard let finishedRange = precedingText.range(
            of: #"\#(tokenPattern)([ \t.,!?;:])$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let matchedText = String(precedingText[finishedRange])
        guard let tokenRange = matchedText.range(of: tokenPattern, options: .regularExpression) else {
            return nil
        }

        let token = String(matchedText[tokenRange])
        let delimiter = String(matchedText[tokenRange.upperBound...])
        return CorrectionTarget(
            token: token,
            trailingDelimiter: delimiter,
            replacedCharacterCount: matchedText.count
        )
    }

    static func correctedText(
        for target: CorrectionTarget,
        candidates: [String]
    ) -> String? {
        guard target.token.range(of: tokenRegex, options: .regularExpression) != nil,
              target.token.uppercased() != target.token
        else {
            return nil
        }

        let normalizedToken = target.token.lowercased()
        let viableCandidates = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { candidate in
                let normalizedCandidate = candidate.lowercased()
                guard candidate.range(of: tokenRegex, options: .regularExpression) != nil,
                      normalizedCandidate != normalizedToken,
                      !normalizedCandidate.hasPrefix(normalizedToken),
                      !normalizedToken.hasPrefix(normalizedCandidate),
                      abs(candidate.count - target.token.count) <= 2
                else {
                    return false
                }

                let distance = editDistance(normalizedToken, normalizedCandidate)
                let allowedDistance = target.token.count >= 7 ? 3 : 2
                return distance > 0
                    && distance <= allowedDistance
                    && normalizedCandidate.first == normalizedToken.first
            }

        guard let bestCandidate = viableCandidates.min(by: { lhs, rhs in
            let lhsScore = candidateScore(lhs, originalToken: target.token)
            let rhsScore = candidateScore(rhs, originalToken: target.token)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            return lhs.count < rhs.count
        }) else {
            return nil
        }

        return bestCandidate + target.trailingDelimiter
    }

    private static func candidateScore(_ candidate: String, originalToken: String) -> Int {
        let normalizedOriginal = originalToken.lowercased()
        let normalizedCandidate = candidate.lowercased()
        let distance = isSingleAdjacentTransposition(normalizedOriginal, normalizedCandidate)
            ? 1
            : editDistance(normalizedOriginal, normalizedCandidate)
        let lengthPenalty = abs(candidate.count - originalToken.count) * 3
        return distance * 10 + lengthPenalty
    }

    private static func isSingleAdjacentTransposition(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard left.count == right.count else {
            return false
        }

        let differingIndices = left.indices.filter { left[$0] != right[$0] }
        guard differingIndices.count == 2,
              let first = differingIndices.first,
              let second = differingIndices.last,
              second == first + 1
        else {
            return false
        }

        return left[first] == right[second] && left[second] == right[first]
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previousRow = Array(0 ... right.count)
        for leftIndex in 1 ... left.count {
            var currentRow = [leftIndex]
            for rightIndex in 1 ... right.count {
                let substitutionCost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                currentRow.append(
                    min(
                        previousRow[rightIndex] + 1,
                        currentRow[rightIndex - 1] + 1,
                        previousRow[rightIndex - 1] + substitutionCost
                    )
                )
            }
            previousRow = currentRow
        }

        return previousRow[right.count]
    }
}

private extension Character {
    var isLetterOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
