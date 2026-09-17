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
        var scenario: ScreenScenario? = nil
    }

    /// A synthetic visible surface before typing starts. This is an OCR transcription fixture,
    /// not an instruction to the model. The adapter owns cleanup and request construction;
    /// keeping source text here lets reviewers audit cues independently of predicted answers.
    struct ScreenScenario: Codable, Equatable {
        let kind: String
        let applicationName: String
        let bundleIdentifier: String
        let windowTitle: String
        let fieldPlaceholder: String
        let documentPrefix: String
        let screenText: String
    }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ValidationError.invalid(message) }
        }
        try require(version == 2 && language == "en", "Unsupported corpus version or language")
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
        try require(Set(phrases.compactMap { $0.scenario?.screenText }).count == 1337, "Each phrase needs its own screen context")
        for phrase in phrases {
            try require(!phrase.id.isEmpty, "Empty phrase ID")
            try require(phrase.text == phrase.text.trimmingCharacters(in: .whitespacesAndNewlines), "Untrimmed phrase")
            try require(PhrasePredictionScorer.wordRanges(in: phrase.text).count >= 3, "Phrase needs at least three words")
            guard let scene = phrase.scenario else { throw ValidationError.invalid("Missing scenario: \(phrase.id)") }
            try require(!scene.applicationName.isEmpty && !scene.bundleIdentifier.isEmpty && !scene.kind.isEmpty, "Incomplete surface")
            try require(scene.screenText.count >= 40 && scene.screenText.count <= 4000, "Screen context outside fixture bounds")
            let answer = Self.normalizedWords(phrase.text)
            let source = Self.normalizedWords(scene.screenText + " " + scene.documentPrefix)
            try require(!source.contains(answer), "Complete reference phrase leaked into context: \(phrase.id)")
        }
    }

    private static func normalizedWords(_ text: String) -> String {
        PhrasePredictionScorer.wordRanges(in: text).map { String(text[$0]).lowercased() }.joined(separator: " ")
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
    enum ContextCondition: String, Codable { case none, screen }
    enum ContextMode: String, Codable {
        case none, screen, paired
        var conditions: [ContextCondition] {
            switch self {
            case .none: return [.none]
            case .screen: return [.screen]
            case .paired: return [.none, .screen]
            }
        }
    }

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
                    prefix: (phrase.scenario?.documentPrefix ?? "") + String(phrase.text[..<caret]),
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
    /// The actual bounded request inputs expose lost/truncated context when an apparent
    /// context regression was really a hygiene or prompt-budget change.
    let screenExcerpt: String?
    let prompt: String?

    let predictedWord: String?
    let correct: Bool
    let wasShown: Bool

    init(checkpoint: PhrasePredictionScorer.Checkpoint, raw: String, shown: String?, suppression: String?,
         latencyMilliseconds: Double, error: String?, screenExcerpt: String? = nil, prompt: String? = nil) {
        self.checkpoint = checkpoint
        self.raw = raw
        self.shown = shown
        self.suppression = suppression
        self.latencyMilliseconds = latencyMilliseconds
        self.error = error
        self.screenExcerpt = screenExcerpt
        self.prompt = prompt
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
        var contextMode: PhrasePredictionScorer.ContextMode = .none
    }

    struct PhraseResult: Codable {
        let phrase: PhrasePredictionCorpus.Phrase
        let observations: [PhrasePredictionObservation]
        let all: PhrasePredictionMetrics
        let nextWord: PhrasePredictionMetrics
        let condition: PhrasePredictionScorer.ContextCondition

        init(phrase: PhrasePredictionCorpus.Phrase, observations: [PhrasePredictionObservation],
             condition: PhrasePredictionScorer.ContextCondition = .none) {
            self.phrase = phrase
            self.observations = observations
            self.condition = condition
            all = PhrasePredictionMetrics(observations)
            nextWord = PhrasePredictionMetrics(observations.filter { $0.checkpoint.typedCharacters == 0 })
        }
    }

    /// Each condition gets independent denominators; combining both would hide whether context
    /// helped. The primary score uses screen results when present, otherwise the no-screen run.
    struct ConditionSummary: Codable {
        let suite: Summary
        let categories: [String: Summary]
        init(_ phrases: [PhraseResult]) {
            suite = Summary(phrases)
            categories = Dictionary(grouping: phrases, by: { $0.phrase.category }).mapValues { Summary($0) }
        }
    }

    /// Paired word-boundary outcomes measure both helpful and harmful changes. A positive net
    /// delta must not conceal cases where the screen distracted an otherwise correct prediction.
    struct ContextLift: Codable {
        let suiteAccuracyDelta: Double
        let byCategory: [String: Double]
        let byPhrase: [String: Double]
        let improvedCheckpoints: Int
        let regressedCheckpoints: Int

        init?(phrases: [PhraseResult], conditions: [String: ConditionSummary]) {
            guard let screen = conditions["screen"], let none = conditions["none"],
                  let screenAccuracy = screen.suite.nextWord.accuracy,
                  let noneAccuracy = none.suite.nextWord.accuracy else { return nil }
            let controls = Dictionary(uniqueKeysWithValues: phrases.filter { $0.condition == .none }.map { ($0.phrase.id, $0) })
            let contextual = phrases.filter { $0.condition == .screen }
            guard contextual.count == controls.count, contextual.allSatisfy({ result in
                guard let control = controls[result.phrase.id] else { return false }
                return control.observations.map(\.checkpoint) == result.observations.map(\.checkpoint)
            }) else { return nil }
            suiteAccuracyDelta = screenAccuracy - noneAccuracy
            byCategory = screen.categories.reduce(into: [:]) { values, entry in
                if let current = entry.value.nextWord.accuracy, let baseline = none.categories[entry.key]?.nextWord.accuracy {
                    values[entry.key] = current - baseline
                }
            }
            var deltas: [String: Double] = [:]
            var improved = 0
            var regressed = 0
            for result in contextual {
                guard let control = controls[result.phrase.id] else { continue }
                if let current = result.nextWord.accuracy, let baseline = control.nextWord.accuracy {
                    deltas[result.phrase.id] = current - baseline
                }
                for (before, after) in zip(control.observations, result.observations) where after.checkpoint.typedCharacters == 0 {
                    if !before.correct && after.correct { improved += 1 }
                    if before.correct && !after.correct { regressed += 1 }
                }
            }
            byPhrase = deltas
            improvedCheckpoints = improved
            regressedCheckpoints = regressed
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
    let primaryCondition: PhrasePredictionScorer.ContextCondition
    let conditions: [String: ConditionSummary]
    let contextLift: ContextLift?
    let errorCount: Int

    init(metadata: Metadata, phrases: [PhraseResult]) {
        schemaVersion = 2
        self.metadata = metadata
        self.phrases = phrases
        measurementScope = "Sequential prefix replay through local llama, request factory, normalization and final seam guard. "
            + "Synthetic OCR text uses production cleanup, selection and prompt budgeting; no screenshots or Vision recognition. "
            + "Prior draft and surface metadata are held fixed across conditions. No future answer, clipboard, real keystrokes, "
            + "debounce, streaming or acceptance-tail reuse. Cache reset between conditions; fixed seed; teacher-forced typing."
        let selectedCondition: PhrasePredictionScorer.ContextCondition = phrases.contains { $0.condition == .screen } ? .screen : .none
        primaryCondition = selectedCondition
        let primary = phrases.filter { $0.condition == selectedCondition }
        suite = Summary(primary)
        categories = Dictionary(grouping: primary, by: { $0.phrase.category }).mapValues { Summary($0) }
        conditions = Dictionary(grouping: phrases, by: { $0.condition.rawValue }).mapValues { ConditionSummary($0) }
        contextLift = ContextLift(phrases: phrases, conditions: conditions)
        errorCount = phrases.reduce(0) { $0 + $1.all.errors }
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
        var lines = [line("SUITE (\(primaryCondition.rawValue))", suite)]
        lines.append("Equal-category next-word score: \(percent(meanCategoryNextWordAccuracy))")
        for category in categories.keys.sorted() {
            if let summary = categories[category] { lines.append(line(category, summary)) }
        }
        if metadata.mode == .character {
            lines.append("All character checkpoints: \(percent(suite.all.accuracy)) (separate from next-word score)")
        }
        if let lift = contextLift, let control = conditions["none"] {
            lines.append(line("WITHOUT SCREEN", control.suite))
            lines.append(String(format: "Screen-context lift: %+.2f percentage points; helped %d, harmed %d word checkpoints",
                                lift.suiteAccuracyDelta * 100, lift.improvedCheckpoints, lift.regressedCheckpoints))
            for category in lift.byCategory.keys.sorted() {
                lines.append(String(format: "  %@ lift %+.2f pp", category, (lift.byCategory[category] ?? 0) * 100))
            }
        }
        return lines.joined(separator: "\n")
    }
}
