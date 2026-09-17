import Foundation

/// The benchmark's immutable input boundary. The runner reads this checked-in corpus once;
/// neither generated suggestions nor user writing can modify the reference phrases.
struct PhrasePredictionCorpus: Codable {
    let version: Int
    let language: String
    let provenance: String
    let phrases: [Phrase]

    /// Stable IDs join runs even when execution is restricted to one category or phrase.
    struct Phrase: Codable, Equatable {
        let id: String
        let category: String
        let text: String
    }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ValidationError.invalid(message) }
        }
        try require(version == 1 && language == "en", "Unsupported corpus version or language")
        try require(!provenance.isEmpty, "Corpus provenance is required")
        try require(phrases.count == 1337, "Expected exactly 1337 phrases")
        try require(Set(phrases.map(\.id)).count == phrases.count, "Duplicate phrase IDs")
        let folded = phrases.map { $0.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        try require(Set(folded).count == phrases.count, "Duplicate phrase text")
        let categories = Dictionary(grouping: phrases, by: \.category)
        try require(Set(categories.keys) == Set([
            "conversation", "science", "entertainment", "work", "technology", "everyday", "travel"
        ]), "Unexpected categories")
        try require(categories.values.allSatisfy { $0.count == 191 }, "Each category must contain 191 phrases")
        for phrase in phrases {
            try require(!phrase.id.isEmpty, "Empty phrase ID")
            try require(phrase.text == phrase.text.trimmingCharacters(in: .whitespacesAndNewlines), "Untrimmed phrase")
            try require(PhrasePredictionScorer.wordRanges(in: phrase.text).count >= 3, "Phrase needs at least three words")
        }
    }

    enum ValidationError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }
}

/// Pure replay and scoring rules shared by the real-model runner and ordinary unit tests.
/// Only prefixes enter inference; the target word and the rest of the phrase stay in this layer.
enum PhrasePredictionScorer {
    enum Mode: String, Codable { case word, character }

    // The pattern is a tested source literal, so failure is a programming error. Include
    // combining marks so a decomposed accent cannot truncate an otherwise correct word.
    private static let wordPattern = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}]*(?:['’\\-][\\p{L}\\p{N}][\\p{L}\\p{N}\\p{M}]*)*"
    )

    /// A snapshot immediately before a target word, or partway through it in character mode.
    /// The first word supplies context and is never scored from an empty prompt.
    struct Checkpoint: Codable, Equatable {
        let wordIndex: Int
        let typedCharacters: Int
        let prefix: String
        let typedWordPrefix: String
        let expectedWord: String
    }

    static func wordRanges(in text: String) -> [Range<String.Index>] {
        // Internal apostrophes and hyphens belong to words: don't == dont is NOT a match.
        // NSRegularExpression speaks UTF-16; Range(_:in:) safely maps back to Swift graphemes.
        return wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }

    static func checkpoints(for phrase: PhrasePredictionCorpus.Phrase, mode: Mode) -> [Checkpoint] {
        wordRanges(in: phrase.text).enumerated().dropFirst().flatMap { index, range in
            let word = String(phrase.text[range])
            let offsets = mode == .word ? [0] : Array(0..<word.count)
            return offsets.map { offset in
                let caret = phrase.text.index(range.lowerBound, offsetBy: offset)
                return Checkpoint(
                    wordIndex: index, typedCharacters: offset,
                    prefix: String(phrase.text[..<caret]),
                    typedWordPrefix: String(phrase.text[range.lowerBound..<caret]), expectedWord: word
                )
            }
        }
    }

    /// Final display text is a continuation, not a replacement. Joining at the caret before
    /// tokenizing catches `sched ule`, repeated prefixes, and words that merely start alike.
    static func predictedWord(shown: String?, at checkpoint: Checkpoint) -> String? {
        guard let shown, !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !checkpoint.typedWordPrefix.isEmpty, let first = shown.first, first.isWhitespace { return nil }
        let joined = checkpoint.typedWordPrefix + shown
        guard let range = wordRanges(in: joined).first else { return nil }
        // Leading punctuation is a different continuation, not an excuse to search ahead for
        // the expected word. Whitespace is harmless only at a fresh word boundary.
        guard joined[..<range.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
        if range.upperBound < joined.endIndex, "'’-".contains(joined[range.upperBound]) { return nil }
        return String(joined[range])
    }

    static func isCorrect(shown: String?, at checkpoint: Checkpoint) -> Bool {
        guard let predicted = predictedWord(shown: shown, at: checkpoint) else { return false }
        return fold(predicted) == fold(checkpoint.expectedWord)
    }

    private static func fold(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'")
    }
}

/// One scored observation retains both raw and display-eligible text, so a regression can be
/// traced to generation versus suppression without rerunning the model. The runner owns these
/// values for one phrase, then serializes them into the report.
struct PhrasePredictionObservation: Codable {
    let checkpoint: PhrasePredictionScorer.Checkpoint
    let raw: String
    let shown: String?
    let suppression: String?
    let latencyMilliseconds: Double
    let error: String?

    let predictedWord: String?
    let correct: Bool
    let wasShown: Bool

    init(checkpoint: PhrasePredictionScorer.Checkpoint, raw: String, shown: String?, suppression: String?,
         latencyMilliseconds: Double, error: String?) {
        self.checkpoint = checkpoint
        self.raw = raw
        self.shown = shown
        self.suppression = suppression
        self.latencyMilliseconds = latencyMilliseconds
        self.error = error
        predictedWord = PhrasePredictionScorer.predictedWord(shown: shown, at: checkpoint)
        correct = error == nil && PhrasePredictionScorer.isCorrect(shown: shown, at: checkpoint)
        wasShown = !(shown ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Serializable aggregate at phrase, category, and suite levels. Accuracy always includes
/// suppressed/error checkpoints in its denominator; precision alone would reward hiding output.
struct PhrasePredictionMetrics: Codable {
    let checkpoints: Int
    let correct: Int
    let shown: Int
    let errors: Int
    let accuracy: Double?
    let coverage: Double?
    let precisionWhenShown: Double?
    let latencyP50Milliseconds: Double?
    let latencyP95Milliseconds: Double?

    init(_ observations: [PhrasePredictionObservation]) {
        checkpoints = observations.count
        correct = observations.filter(\.correct).count
        shown = observations.filter(\.wasShown).count
        errors = observations.filter { $0.error != nil }.count
        accuracy = checkpoints > 0 ? Double(correct) / Double(checkpoints) : nil
        coverage = checkpoints > 0 ? Double(shown) / Double(checkpoints) : nil
        precisionWhenShown = shown > 0 ? Double(correct) / Double(shown) : nil
        // A gated request never called the model. Its zero is not a latency sample.
        let latencies = observations.filter { $0.suppression != "pre-generation-gate" && $0.error == nil }
            .map(\.latencyMilliseconds).sorted()
        func percentile(_ fraction: Double) -> Double? {
            guard !latencies.isEmpty else { return nil }
            return latencies[max(0, Int(ceil(Double(latencies.count) * fraction)) - 1)]
        }
        latencyP50Milliseconds = percentile(0.5)
        latencyP95Milliseconds = percentile(0.95)
    }
}

/// Report structure is deliberately independent of XCTest and inference. The runner produces
/// observations; this value derives all aggregates once, making JSON and printed scores agree.
struct PhrasePredictionReport: Codable {
    /// Identity and execution settings travel with scores, preventing accidental comparisons
    /// across corpora, sampling modes, or phrase selections. The CLI also records the git diff.
    struct Metadata: Codable {
        let corpusSHA256: String
        let corpusVersion: Int
        let model: String
        let seed: UInt32
        let mode: PhrasePredictionScorer.Mode
        let configuration: [String: String]
        let runLabel: String
    }

    struct PhraseResult: Codable {
        let phrase: PhrasePredictionCorpus.Phrase
        let observations: [PhrasePredictionObservation]
        let all: PhrasePredictionMetrics
        let nextWord: PhrasePredictionMetrics

        init(phrase: PhrasePredictionCorpus.Phrase, observations: [PhrasePredictionObservation]) {
            self.phrase = phrase
            self.observations = observations
            all = PhrasePredictionMetrics(observations)
            nextWord = PhrasePredictionMetrics(observations.filter { $0.checkpoint.typedCharacters == 0 })
        }
    }

    struct Summary: Codable {
        let phraseCount: Int
        let all: PhrasePredictionMetrics
        let nextWord: PhrasePredictionMetrics
        let meanPhraseNextWordAccuracy: Double?

        init(_ phrases: [PhraseResult]) {
            phraseCount = phrases.count
            let observations = phrases.flatMap(\.observations)
            all = PhrasePredictionMetrics(observations)
            nextWord = PhrasePredictionMetrics(observations.filter { $0.checkpoint.typedCharacters == 0 })
            let scores = phrases.compactMap { $0.nextWord.accuracy }
            meanPhraseNextWordAccuracy = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        }
    }

    let schemaVersion: Int
    let metadata: Metadata
    let measurementScope: String
    let suite: Summary
    let categories: [String: Summary]
    let meanCategoryNextWordAccuracy: Double?
    let phrases: [PhraseResult]

    init(metadata: Metadata, phrases: [PhraseResult]) {
        schemaVersion = 1
        self.metadata = metadata
        self.phrases = phrases
        measurementScope = "Sequential prefix replay through local llama, request factory, normalization and final seam guard. "
            + "No reference suffix, category, screen, clipboard, real keystrokes, debounce, streaming or acceptance-tail reuse. "
            + "Cache reset between phrases; fixed seed; teacher-forced reference typing. Exact next-word match, not semantic quality."
        suite = Summary(phrases)
        categories = Dictionary(grouping: phrases, by: { $0.phrase.category }).mapValues { Summary($0) }
        let scores = categories.values.compactMap { $0.nextWord.accuracy }
        meanCategoryNextWordAccuracy = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
    }

    func rendered() -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", 100 * $0) } ?? "n/a" }
        func line(_ name: String, _ summary: Summary) -> String {
            "\(name): \(summary.phraseCount) phrases, next-word \(percent(summary.nextWord.accuracy)) "
                + "(\(summary.nextWord.correct)/\(summary.nextWord.checkpoints)), "
                + "coverage \(percent(summary.nextWord.coverage)), precision \(percent(summary.nextWord.precisionWhenShown))"
        }
        var lines = [line("SUITE", suite)]
        lines.append("Equal-category next-word score: \(percent(meanCategoryNextWordAccuracy))")
        for category in categories.keys.sorted() {
            if let summary = categories[category] { lines.append(line(category, summary)) }
        }
        if metadata.mode == .character {
            lines.append("All character checkpoints: \(percent(suite.all.accuracy)) (separate from next-word score)")
        }
        return lines.joined(separator: "\n")
    }
}
