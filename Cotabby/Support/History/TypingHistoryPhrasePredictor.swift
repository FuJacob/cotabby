import Foundation

/// Predicts the rest of a phrase the user has typed many times before, without a model.
///
/// The idea: after "Best regards," the user writes "Senad" nearly every time; after "let me know"
/// they usually write "if you have any questions." A word-level n-gram table built from history
/// answers those instantly and in the user's exact wording, which a general model can only guess.
///
/// It is intentionally strict. A continuation is offered only when the same three words were
/// followed by the same next word at least `minimumCount` times and in at least `minimumShare` of
/// cases, and the chain stops at the first word history is unsure about. Anything less confident
/// falls through to the model, so a shortcut is either clearly right or absent.
///
/// Built off the main actor; `continuation(after:)` runs on the main actor per request and is a
/// handful of dictionary lookups.
nonisolated struct TypingHistoryPhrasePredictor: Sendable {
    struct Limits: Equatable, Sendable {
        var maxWords: Int
        var allowsNewlines: Bool
    }

    private static let contextLength = 3
    private static let minimumCount: Int32 = 3
    private static let minimumShare = 0.6
    /// When the last three words were never seen together, the last two are tried instead. Two
    /// words predict less, so that fallback needs more evidence and a clearer winner.
    private static let backoffMinimumCount: Int32 = 5
    private static let backoffMinimumShare = 0.7
    /// Marks a context word history has never seen, so the three-word lookup misses cleanly.
    private static let unknownToken: Int32 = -1
    /// A one-word shortcut ("Senad" after "Best regards,") needs more evidence than a longer chain,
    /// because a single common word is more likely to be a coincidence.
    private static let minimumSingleWordCount: Int32 = 5
    private static let newlineToken = "\n"

    private struct Context: Hashable, Sendable {
        let first: Int32
        let second: Int32
        let third: Int32
    }

    private struct ShortContext: Hashable, Sendable {
        let first: Int32
        let second: Int32
    }

    /// Lowercased token -> id. Ids index `displayForms`.
    private let vocabulary: [String: Int32]
    /// The spelling to insert for each token, as the user last wrote it ("Senad", "POC").
    private let displayForms: [String]
    /// Next-token counts for contexts seen at least `minimumCount` times.
    private let continuations: [Context: [Int32: Int32]]
    /// Two-word fallback, kept only for pairs seen at least `backoffMinimumCount` times.
    private let shortContinuations: [ShortContext: [Int32: Int32]]

    var contextCount: Int { continuations.count }

    init(records: [TypingHistoryRecord]) {
        var vocabulary: [String: Int32] = [:]
        var displayForms: [String] = []
        var sequences: [[Int32]] = []
        sequences.reserveCapacity(records.count)
        for record in records {
            var ids: [Int32] = []
            // Learn only from what the user typed, so names and phrasing in quoted replies below the
            // caret never become the user's shortcuts.
            for token in Self.tokens(in: record.typedText) {
                let key = token.lowercased()
                if let id = vocabulary[key] {
                    displayForms[Int(id)] = token
                    ids.append(id)
                } else {
                    let id = Int32(displayForms.count)
                    vocabulary[key] = id
                    displayForms.append(token)
                    ids.append(id)
                }
            }
            sequences.append(ids)
        }

        // Two passes keep memory bounded: count every context first, then collect next-token
        // counts only for contexts frequent enough to ever produce a shortcut.
        var contextCounts: [Context: Int32] = [:]
        for ids in sequences where ids.count > Self.contextLength {
            for index in Self.contextLength..<ids.count {
                contextCounts[Context(first: ids[index - 3], second: ids[index - 2], third: ids[index - 1]), default: 0] += 1
            }
        }
        var continuations: [Context: [Int32: Int32]] = [:]
        for ids in sequences where ids.count > Self.contextLength {
            for index in Self.contextLength..<ids.count {
                let context = Context(first: ids[index - 3], second: ids[index - 2], third: ids[index - 1])
                guard let count = contextCounts[context], count >= Self.minimumCount else { continue }
                continuations[context, default: [:]][ids[index], default: 0] += 1
            }
        }

        var shortCounts: [ShortContext: Int32] = [:]
        for ids in sequences where ids.count > 2 {
            for index in 2..<ids.count {
                shortCounts[ShortContext(first: ids[index - 2], second: ids[index - 1]), default: 0] += 1
            }
        }
        var shortContinuations: [ShortContext: [Int32: Int32]] = [:]
        for ids in sequences where ids.count > 2 {
            for index in 2..<ids.count {
                let context = ShortContext(first: ids[index - 2], second: ids[index - 1])
                guard let count = shortCounts[context], count >= Self.backoffMinimumCount else { continue }
                shortContinuations[context, default: [:]][ids[index], default: 0] += 1
            }
        }

        self.vocabulary = vocabulary
        self.displayForms = displayForms
        self.continuations = continuations
        self.shortContinuations = shortContinuations
    }

    /// The exact text to insert after `precedingText`, or nil when history is not confident.
    ///
    /// When the caret is inside a word ("Best reg"), the typed letters filter the first word and
    /// only its untyped remainder is returned ("ards, Senad"). Otherwise the result starts with
    /// the separating space.
    func continuation(after precedingText: String, limits: Limits) -> String? {
        let endsAtBoundary = precedingText.last.map { $0.isWhitespace } ?? true
        var tokens = Self.tokens(in: String(precedingText.suffix(400)))
        let partial = endsAtBoundary ? nil : tokens.popLast()
        guard tokens.count >= 2 else { return nil }

        // The two words nearest the caret must be known; the third may be new (it only selects the
        // three-word table), in which case the two-word fallback answers.
        var ids: [Int32] = tokens.count >= Self.contextLength ? [] : [Self.unknownToken]
        for (offset, token) in tokens.suffix(Self.contextLength).enumerated() {
            let isNearCaret = offset >= min(tokens.count, Self.contextLength) - 2
            if let id = vocabulary[token.lowercased()] {
                ids.append(id)
            } else if isNearCaret {
                return nil
            } else {
                ids.append(Self.unknownToken)
            }
        }

        var output = ""
        var words = 0
        var weakestCount = Int32.max
        var isFirstStep = true
        while words < limits.maxWords {
            let prefixFilter = isFirstStep ? partial?.lowercased() : nil
            let context = Context(first: ids[ids.count - 3], second: ids[ids.count - 2], third: ids[ids.count - 1])
            let shortContext = ShortContext(first: ids[ids.count - 2], second: ids[ids.count - 1])
            let choice: (Int32, Int32)?
            if let candidates = continuations[context] {
                choice = Self.confidentCandidate(
                    in: candidates, displayForms: displayForms, prefix: prefixFilter,
                    minimumCount: Self.minimumCount, minimumShare: Self.minimumShare
                )
            } else if let candidates = shortContinuations[shortContext] {
                choice = Self.confidentCandidate(
                    in: candidates, displayForms: displayForms, prefix: prefixFilter,
                    minimumCount: Self.backoffMinimumCount, minimumShare: Self.backoffMinimumShare
                )
            } else {
                choice = nil
            }
            guard let (nextID, count) = choice else { break }
            let token = displayForms[Int(nextID)]

            if token == Self.newlineToken {
                guard limits.allowsNewlines, !isFirstStep || partial == nil else { break }
                output += "\n"
            } else if isFirstStep, let partial {
                output += String(token.dropFirst(partial.count))
                words += 1
            } else {
                // A space separates words, except right after a line break or at the very start
                // when the field already ends in whitespace the user typed.
                let separator = output.hasSuffix("\n") || (output.isEmpty && endsAtBoundary) ? "" : " "
                output += separator + token
                words += 1
            }
            weakestCount = min(weakestCount, count)
            ids.append(nextID)
            isFirstStep = false
            if token.last.map({ ".!?".contains($0) }) == true { break }
        }

        let visible = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        if words < 2, weakestCount < Self.minimumSingleWordCount { return nil }
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    private static func confidentCandidate(
        in candidates: [Int32: Int32],
        displayForms: [String],
        prefix: String?,
        minimumCount: Int32,
        minimumShare: Double
    ) -> (Int32, Int32)? {
        let eligible = prefix.map { prefix in
            candidates.filter { id, _ in
                let form = displayForms[Int(id)].lowercased()
                return form != newlineToken && form.hasPrefix(prefix)
            }
        } ?? candidates
        let total = eligible.values.reduce(0, +)
        guard let best = eligible.max(by: { $0.value < $1.value }), total > 0,
              best.value >= minimumCount, Double(best.value) / Double(total) >= minimumShare
        else { return nil }
        return (best.key, best.value)
    }

    /// Splits on spaces and tabs, keeping punctuation attached ("regards,") and turning each line
    /// break into its own token so sign-offs that span lines can be learned.
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                if !current.isEmpty { tokens.append(current); current = "" }
                if tokens.last != newlineToken { tokens.append(newlineToken) }
            } else if character.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
