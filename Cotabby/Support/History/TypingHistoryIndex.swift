import Foundation

/// What a retrieval looks for: the stable part of the text being written plus where it is written.
nonisolated struct TypingHistoryQuery: Equatable, Sendable {
    /// Words that characterize the current writing (see `TypingHistoryQuery.stableText`).
    let text: String
    let bundleIdentifier: String
    let domain: String?
    /// The live field text. A history entry that contains its tail is the same document (an older
    /// snapshot of this very field), and showing the model its own draft would only make it echo.
    let currentFieldText: String

    /// Builds the query text from the caret prefix, rounded down to a whole block of words.
    ///
    /// The llama runtime reuses its KV cache for the unchanged head of the prompt, and examples sit
    /// in that head. Querying on every keystroke would change the examples, and with them the cached
    /// prefix, on nearly every request. Rounding to blocks of `wordsPerBlock` words keeps the
    /// examples fixed while a few words are typed and refreshes them as the topic moves on.
    static func stableText(from precedingText: String, wordsPerBlock: Int = 8, maxWords: Int = 48) -> String {
        let words = precedingText.split(whereSeparator: \.isWhitespace)
        let completeBlocks = (words.count / wordsPerBlock) * wordsPerBlock
        guard completeBlocks > 0 else { return "" }
        let window = words[..<completeBlocks].suffix(maxWords)
        return window.joined(separator: " ")
    }
}

/// An immutable, searchable view of typing history for prompt examples.
///
/// Built off the main actor whenever history changes; queried synchronously on the main actor while
/// a request is assembled, so lookups must stay cheap. It is a plain inverted index with IDF
/// weighting: a past text scores by how many of the query's informative words it shares, with a
/// boost for the same app or site. No embeddings or model calls, so it is fast, deterministic, and
/// testable.
nonisolated struct TypingHistoryIndex: Sendable {
    private struct Document: Sendable {
        let bundleIdentifier: String
        let domain: String?
        let text: String
    }

    /// Documents shorter than this rarely carry enough wording to be a useful example.
    private static let minimumDocumentCharacters = 40
    /// A match must share at least this much IDF weight with the query; below it, examples are
    /// coincidental and only add noise to the prompt.
    private static let minimumScore = 6.0
    private static let sameAppBoost = 1.3
    private static let sameDomainBoost = 1.6

    private let documents: [Document]
    private let postings: [String: [Int32]]
    private let inverseDocumentFrequency: [String: Double]

    var documentCount: Int { documents.count }

    init(records: [TypingHistoryRecord]) {
        var documents: [Document] = []
        var postings: [String: [Int32]] = [:]
        // Only what the user typed becomes an example; the rest of the field is often someone
        // else's writing (a quoted email thread).
        for record in records {
            let text = record.typedText
            guard text.count >= Self.minimumDocumentCharacters else { continue }
            let index = Int32(documents.count)
            documents.append(Document(bundleIdentifier: record.bundleIdentifier, domain: record.domain, text: text))
            for term in Set(Self.terms(in: text)) {
                postings[term, default: []].append(index)
            }
        }
        let count = Double(documents.count)
        self.documents = documents
        self.postings = postings
        // Smoothed IDF: every shared word counts at least 1, rarer words count more. Unsmoothed
        // log(N/df) drops to zero for a word in every document, which in a small history made
        // even a close match score nothing.
        self.inverseDocumentFrequency = postings.mapValues { log((count + 1) / Double($0.count)) + 1 }
    }

    /// Returns up to `limit` passages from past writing that best match the query, each at most
    /// `maxCharacters` long, best first.
    func examples(for query: TypingHistoryQuery, limit: Int = 2, maxCharacters: Int = 320) -> [String] {
        let queryTerms = Set(Self.terms(in: query.text))
        guard !queryTerms.isEmpty, limit > 0 else { return [] }

        var scores: [Int32: Double] = [:]
        for term in queryTerms {
            guard let weight = inverseDocumentFrequency[term], let documentIDs = postings[term] else { continue }
            for documentID in documentIDs {
                scores[documentID, default: 0] += weight
            }
        }

        let currentTail = String(query.currentFieldText.suffix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let ranked = scores
            .map { documentID, score -> (Int32, Double) in
                let document = documents[Int(documentID)]
                var boosted = score
                if document.bundleIdentifier == query.bundleIdentifier { boosted *= Self.sameAppBoost }
                if let domain = query.domain, document.domain == domain { boosted *= Self.sameDomainBoost }
                return (documentID, boosted)
            }
            .filter { $0.1 >= Self.minimumScore }
            .sorted { $0.1 > $1.1 }

        var passages: [String] = []
        for (documentID, _) in ranked {
            let text = documents[Int(documentID)].text
            if Self.isSameDocument(text, currentText: query.currentFieldText, currentTail: currentTail) { continue }
            let passage = Self.bestPassage(in: text, terms: queryTerms, maxCharacters: maxCharacters)
            guard !passage.isEmpty, !passages.contains(passage) else { continue }
            passages.append(passage)
            if passages.count == limit { break }
        }
        return passages
    }

    /// True when a history entry is another version of the text being typed: an earlier snapshot
    /// (the field now contains its opening) or a later one (it contains the field's latest words).
    private static func isSameDocument(_ text: String, currentText: String, currentTail: String) -> Bool {
        let opening = String(text.prefix(60))
        if opening.count >= 20, currentText.contains(opening) { return true }
        return currentTail.count >= 20 && text.contains(currentTail)
    }

    // MARK: - Text helpers

    private static let stopWords: Set<String> = Set("""
    a an the and or but if then so to of in on at for with from by as is are was were be been being it its \
    this that these those i you he she we they me my your our their them us do does did not no yes can could \
    will would should have has had just also very more most some any all what which who when where why how \
    there here than too up out about into over after before again only own same other such each few both \
    one get got make made like well back still even way go going know think see want need please thanks \
    thank hi hello ok okay im dont ive ill let lets sure yeah
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Lowercased words of two or more letters or digits, minus stop words.
    static func terms(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .filter { $0.count >= 2 }
            .map(String.init)
            .filter { !stopWords.contains($0) }
    }

    /// Picks the sentence with the most query terms and grows it with its neighbors while it fits,
    /// so the example reads as the user's own sentence rather than a mid-word cut.
    private static func bestPassage(in text: String, terms: Set<String>, maxCharacters: Int) -> String {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return "" }
        let hits = sentences.map { sentence in Self.terms(in: sentence).filter(terms.contains).count }
        guard let best = hits.indices.max(by: { hits[$0] < hits[$1] }) else { return "" }

        var lower = best
        var upper = best
        var length = sentences[best].count
        while true {
            let canGrowDown = lower > 0 && length + sentences[lower - 1].count + 1 <= maxCharacters
            let canGrowUp = upper < sentences.count - 1 && length + sentences[upper + 1].count + 1 <= maxCharacters
            if canGrowUp, !canGrowDown || hits[upper + 1] >= hits[lower - 1] {
                upper += 1
                length += sentences[upper].count + 1
            } else if canGrowDown {
                lower -= 1
                length += sentences[lower].count + 1
            } else {
                break
            }
        }
        let passage = sentences[lower...upper].joined(separator: " ")
        guard passage.count > maxCharacters else { return passage }
        // One very long sentence: keep whole words up to the cap.
        var clipped = String(passage.prefix(maxCharacters))
        if let lastSpace = clipped.lastIndex(of: " ") {
            clipped = String(clipped[..<lastSpace])
        }
        return clipped
    }

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                appendTrimmed(current, to: &sentences)
                current = ""
                continue
            }
            current.append(character)
            if ".!?".contains(character) {
                appendTrimmed(current, to: &sentences)
                current = ""
            }
        }
        appendTrimmed(current, to: &sentences)
        return sentences
    }

    private static func appendTrimmed(_ sentence: String, to sentences: inout [String]) {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { sentences.append(trimmed) }
    }
}
