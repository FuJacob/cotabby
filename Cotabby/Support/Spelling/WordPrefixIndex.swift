import Foundation

/// Immutable exact-prefix vocabulary, built alongside each SymSpell dictionary off the main actor.
/// Correction edit distance has no role here: every returned word starts with the typed letters.
/// A sorted array permits bounded binary-search lookups without scanning 80,000 words per pause.
nonisolated struct WordPrefixIndex: Sendable {
    struct Candidate: Equatable, Sendable {
        let word: String
        let frequency: Int64
    }

    private let words: [Candidate]

    init(contents: String) {
        words = contents.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, let count = Int64(fields[1]), count > 0,
                  fields[0].allSatisfy({ $0.isLetter }) else { return nil }
            return Candidate(word: String(fields[0]), frequency: count)
        }.sorted { $0.word < $1.word }
    }

    func candidates(for prefix: String) -> [Candidate] {
        let prefix = prefix.lowercased()
        guard prefix.count >= 3 else { return [] }
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].word < prefix { low = middle + 1 } else { high = middle }
        }
        var matches: [Candidate] = []
        while low < words.count, words[low].word.hasPrefix(prefix) {
            // A very broad prefix is ambiguous. Abstain rather than rank an arbitrary truncated
            // subset whose unseen candidates could have won.
            guard matches.count < 512 else { return [] }
            if words[low].word != prefix { matches.append(words[low]) }
            low += 1
        }
        return Array(matches.sorted {
            $0.frequency == $1.frequency ? $0.word < $1.word : $0.frequency > $1.frequency
        }.prefix(2))
    }
}

/// Pure local fallback and reference vocabulary for one request. The coordinator supplies only
/// bounded current-document text and the user's existing glossary; nothing is persisted or sent
/// to a backend. Reference words also prevent spelling checks from rejecting established jargon.
nonisolated enum WordCompletionFallback {
    static func referenceWords(precedingText: String, trailingText: String, glossary: String) -> Set<String> {
        var preceding = String(precedingText.suffix(4000))
        if let partial = CaretWordContext.unfinishedWord(in: preceding) {
            preceding.removeLast(partial.count)
        }
        let source = preceding + " " + trailingText.prefix(2000) + " " + glossary.prefix(1300)
        return Set(source.split(whereSeparator: { !$0.isLetter && !CaretWordContext.isConnector($0) })
            .filter { $0.first?.isLetter == true && $0.last?.isLetter == true }
            .map(String.init))
    }

    /// Unique document/glossary matches take precedence. Corpus candidates need a clear frequency
    /// margin; frequency is a fallback ranking signal, never permission to change typed letters.
    static func suffix(
        for prefix: String, references: Set<String>, dictionaryCandidates: [WordPrefixIndex.Candidate]
    ) -> String? {
        guard prefix.count >= 3, prefix.allSatisfy({ $0.isLetter }) else { return nil }
        let matches = references.filter {
            $0.count > prefix.count && $0.lowercased().hasPrefix(prefix.lowercased())
        }
        let uniqueSpellings = Set(matches.map { $0.lowercased() })
        let word: String
        if uniqueSpellings.count == 1, let match = matches.sorted().first {
            word = match
        } else if !matches.isEmpty {
            return nil
        } else {
            guard let first = dictionaryCandidates.first,
                  dictionaryCandidates.count == 1
                    || Double(first.frequency) >= Double(dictionaryCandidates[1].frequency) * 4 else { return nil }
            word = first.word
        }
        guard word.count > prefix.count,
              String(word.prefix(prefix.count)).lowercased() == prefix.lowercased() else { return nil }
        let suffix = String(word.dropFirst(prefix.count))
        return prefix.allSatisfy({ $0.isUppercase }) ? suffix.uppercased() : suffix
    }
}
