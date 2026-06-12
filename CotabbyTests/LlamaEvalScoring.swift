import Foundation

/// Pure scoring layer for the llama suggestion eval: the case schema, the shown-vs-acceptable
/// matcher, the outcome taxonomy, and report aggregation.
///
/// Lives in the test target (it is measurement tooling, not product code) but contains no XCTest
/// so the CI-run `LlamaEvalScoringTests` can exercise every rule without a model.
///
/// Scoring is deliberately non-negative with suppression scored per expectation kind, so neither
/// "show everything" nor "suppress everything" can win the aggregate: wrong text scores 0 where
/// suppression would have scored 0.3 or 1.0, and suppression on a must-show positive scores 0
/// where a correct insert would have scored 1.0.
enum LlamaEvalExpectationKind: String, Decodable {
    /// A continuation is wanted; `acceptable` lists reference continuations.
    case positive
    /// Showing anything is wrong (duplicate-of-trailing, gibberish); suppression is correct.
    case negative
    /// Showing is fine unless the text contains one of `forbidden`; suppression also correct.
    case forbidden
}

struct LlamaEvalExpectation: Decodable, Equatable {
    let kind: LlamaEvalExpectationKind
    /// Positive only: suppressing scores 0 instead of the acceptable-suppression 0.3.
    var mustShow: Bool = false
    /// Positive only: reference continuations the shown text is matched against.
    var acceptable: [String] = []
    /// Forbidden only: substrings that must never appear in shown text (case-insensitive).
    var forbidden: [String] = []
    /// Negative only: documentation of why showing anything is wrong.
    var reason: String?

    private enum CodingKeys: String, CodingKey {
        case kind, mustShow, acceptable, forbidden, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(LlamaEvalExpectationKind.self, forKey: .kind)
        mustShow = try container.decodeIfPresent(Bool.self, forKey: .mustShow) ?? false
        acceptable = try container.decodeIfPresent([String].self, forKey: .acceptable) ?? []
        forbidden = try container.decodeIfPresent([String].self, forKey: .forbidden) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    init(
        kind: LlamaEvalExpectationKind,
        mustShow: Bool = false,
        acceptable: [String] = [],
        forbidden: [String] = [],
        reason: String? = nil
    ) {
        self.kind = kind
        self.mustShow = mustShow
        self.acceptable = acceptable
        self.forbidden = forbidden
        self.reason = reason
    }
}

struct LlamaEvalCase: Decodable, Equatable {
    let id: String
    let tags: [String]
    var applicationName: String = "TestApp"
    var bundleIdentifier: String = "com.example.TestApp"
    let precedingText: String
    var trailingText: String = ""
    var isMultiLineEnabled: Bool = true
    let expectation: LlamaEvalExpectation

    private enum CodingKeys: String, CodingKey {
        case id, tags, applicationName, bundleIdentifier
        case precedingText, trailingText, isMultiLineEnabled, expectation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tags = try container.decode([String].self, forKey: .tags)
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName) ?? "TestApp"
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            ?? "com.example.TestApp"
        precedingText = try container.decode(String.self, forKey: .precedingText)
        trailingText = try container.decodeIfPresent(String.self, forKey: .trailingText) ?? ""
        isMultiLineEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMultiLineEnabled) ?? true
        expectation = try container.decode(LlamaEvalExpectation.self, forKey: .expectation)
    }

    init(
        id: String,
        tags: [String],
        applicationName: String = "TestApp",
        bundleIdentifier: String = "com.example.TestApp",
        precedingText: String,
        trailingText: String = "",
        isMultiLineEnabled: Bool = true,
        expectation: LlamaEvalExpectation
    ) {
        self.id = id
        self.tags = tags
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.precedingText = precedingText
        self.trailingText = trailingText
        self.isMultiLineEnabled = isMultiLineEnabled
        self.expectation = expectation
    }

    static func loadDataset(from url: URL) throws -> [LlamaEvalCase] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([LlamaEvalCase].self, from: data)
    }
}

enum LlamaEvalOutcome: String, CaseIterable {
    case correctInsert
    case correctSuppression
    case acceptableSuppression
    case wrongShown
    case missedShow

    var score: Double {
        switch self {
        case .correctInsert, .correctSuppression: return 1.0
        case .acceptableSuppression: return 0.3
        case .wrongShown, .missedShow: return 0.0
        }
    }
}

enum LlamaEvalScorer {
    /// `shownText` is the final visible suggestion after the full production pipeline, or nil when
    /// it was suppressed anywhere along it.
    static func outcome(shownText: String?, for evalCase: LlamaEvalCase) -> LlamaEvalOutcome {
        switch evalCase.expectation.kind {
        case .positive:
            guard let shown = shownText, !shown.isEmpty else {
                return evalCase.expectation.mustShow ? .missedShow : .acceptableSuppression
            }
            return matches(shown: shown, acceptable: evalCase.expectation.acceptable)
                ? .correctInsert
                : .wrongShown
        case .negative:
            return shownText == nil ? .correctSuppression : .wrongShown
        case .forbidden:
            guard let shown = shownText else { return .correctSuppression }
            let lowered = shown.lowercased()
            let violates = evalCase.expectation.forbidden.contains { lowered.contains($0.lowercased()) }
            return violates ? .wrongShown : .correctInsert
        }
    }

    /// Word-boundary prefix match in either direction: the shown text may extend a reference
    /// continuation or stop early inside one, but the words it does show must be the reference's
    /// words. Case-folded; punctuation folded out of each word; whitespace collapsed. When both
    /// sides collapse to a single folded "word" (single English words, or space-free scripts like
    /// CJK where the whole clause is one run), single ASCII words must match exactly and CJK runs
    /// match on a character prefix.
    static func matches(shown: String, acceptable: [String]) -> Bool {
        acceptable.contains { reference in
            let shownWords = foldedWords(shown)
            let referenceWords = foldedWords(reference)
            guard let firstShown = shownWords.first, let firstReference = referenceWords.first else {
                return false
            }

            if shownWords.count == 1, referenceWords.count == 1 {
                let bothASCII = firstShown.allSatisfy(\.isASCII) && firstReference.allSatisfy(\.isASCII)
                return bothASCII ? firstShown == firstReference : characterPrefixMatch(shown, reference)
            }

            let overlap = min(shownWords.count, referenceWords.count)
            return Array(shownWords.prefix(overlap)) == Array(referenceWords.prefix(overlap))
        }
    }

    private static func foldedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in String(word.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
    }

    private static func foldedCharacters(_ text: String) -> [Character] {
        Array(text.lowercased().filter { !$0.isWhitespace })
    }

    private static func characterPrefixMatch(_ first: String, _ second: String) -> Bool {
        let firstFolded = foldedCharacters(first)
        let secondFolded = foldedCharacters(second)
        let overlap = min(firstFolded.count, secondFolded.count)
        guard overlap >= 2 else { return false }
        return Array(firstFolded.prefix(overlap)) == Array(secondFolded.prefix(overlap))
    }
}

/// One executed case, ready for aggregation.
struct LlamaEvalCaseResult {
    let evalCase: LlamaEvalCase
    let shownText: String?
    let rawText: String
    let outcome: LlamaEvalOutcome
    let suppressionStage: String?
    let latencySeconds: Double
}

struct LlamaEvalReport {
    let modelLabel: String
    let results: [LlamaEvalCaseResult]

    var qualityScore: Double {
        guard !results.isEmpty else { return 0 }
        return results.map(\.outcome.score).reduce(0, +) / Double(results.count)
    }

    var shownCount: Int { results.filter { $0.shownText != nil }.count }

    var precisionWhenShown: Double {
        let shown = results.filter { $0.shownText != nil }
        guard !shown.isEmpty else { return 0 }
        let correct = shown.filter { $0.outcome == .correctInsert }.count
        return Double(correct) / Double(shown.count)
    }

    var wrongShowRate: Double {
        guard !results.isEmpty else { return 0 }
        return Double(results.filter { $0.outcome == .wrongShown }.count) / Double(results.count)
    }

    var positiveCoverage: Double {
        let positives = results.filter { $0.evalCase.expectation.kind == .positive }
        guard !positives.isEmpty else { return 0 }
        let shown = positives.filter { $0.shownText != nil }.count
        return Double(shown) / Double(positives.count)
    }

    func latencyPercentile(_ percentile: Double) -> Double {
        let sorted = results.map(\.latencySeconds).sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[rank]
    }

    func rendered() -> String {
        var lines: [String] = []
        lines.append("=== Llama suggestion eval: \(modelLabel) — \(results.count) cases ===")
        lines.append(String(
            format: "qualityScore %.3f | precisionWhenShown %.3f | positiveCoverage %.3f | wrongShowRate %.3f | shown %d/%d",
            qualityScore, precisionWhenShown, positiveCoverage, wrongShowRate, shownCount, results.count
        ))
        lines.append(String(
            format: "latency p50 %.0fms p95 %.0fms max %.0fms",
            latencyPercentile(0.5) * 1000, latencyPercentile(0.95) * 1000, latencyPercentile(1.0) * 1000
        ))

        var outcomeCounts: [LlamaEvalOutcome: Int] = [:]
        for result in results { outcomeCounts[result.outcome, default: 0] += 1 }
        let outcomeSummary = LlamaEvalOutcome.allCases
            .compactMap { outcome -> String? in
                guard let count = outcomeCounts[outcome] else { return nil }
                return "\(outcome.rawValue) \(count)"
            }
            .joined(separator: " | ")
        lines.append("outcomes: \(outcomeSummary)")

        let allTags = Set(results.flatMap { $0.evalCase.tags }).sorted()
        for tag in allTags {
            let tagged = results.filter { $0.evalCase.tags.contains(tag) }
            let score = tagged.map(\.outcome.score).reduce(0, +) / Double(tagged.count)
            let wrong = tagged.filter { $0.outcome == .wrongShown }.count
            lines.append(String(
                format: "  [%@] n=%d score %.3f wrongShown %d",
                tag, tagged.count, score, wrong
            ))
        }

        for result in results where result.outcome == .wrongShown || result.outcome == .missedShow {
            let shownPreview = (result.shownText ?? "<suppressed>").prefix(80)
            lines.append("  !! \(result.outcome.rawValue) \(result.evalCase.id): \"\(shownPreview)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// Machine-readable artifact for diffing runs across branches.
    func jsonArtifact() throws -> Data {
        var payload: [String: Any] = [
            "model": modelLabel,
            "caseCount": results.count,
            "qualityScore": qualityScore,
            "precisionWhenShown": precisionWhenShown,
            "positiveCoverage": positiveCoverage,
            "wrongShowRate": wrongShowRate,
            "latencyP50Ms": latencyPercentile(0.5) * 1000,
            "latencyP95Ms": latencyPercentile(0.95) * 1000,
            // The printed report includes max; the artifact must too, or the worst-case decode
            // tail (exactly what the scaffolding-marker stop targets) is invisible in run diffs.
            "latencyMaxMs": latencyPercentile(1.0) * 1000
        ]
        payload["cases"] = results.map { result -> [String: Any] in
            [
                "id": result.evalCase.id,
                "outcome": result.outcome.rawValue,
                "shown": result.shownText ?? NSNull(),
                "raw": result.rawText,
                "suppressionStage": result.suppressionStage ?? NSNull(),
                "latencyMs": result.latencySeconds * 1000
            ]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
