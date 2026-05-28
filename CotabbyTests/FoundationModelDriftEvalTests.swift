import XCTest
@testable import Cotabby

#if canImport(FoundationModels)

/// Live Apple Intelligence drift and quality eval — deliberately NOT a CI test.
///
/// Apple's system model is chat-tuned. Historically it broke character on plain prefixes: greeting
/// the user ("Jacob, how are you"), tacking on pleasantries ("Hope it's going well"), or replying
/// like an assistant. The chat-drift bucket below preserves those failing cases; the other buckets
/// (email, slack, code, code-comment, prose, mid-line insertion) widen coverage to the writing
/// surfaces real users complain about so prompt and engine changes can be measured per category
/// instead of averaged into one number.
///
/// Per-case scoring captures four signals:
///   - DRIFT     — output reads as an assistant reply (a "drift tell" phrase or unprompted greeting)
///   - EMPTY     — normalization stripped the output to nothing (a hard miss in production)
///   - NOISE     — chat-template residue leaked through (regression check for routing/normalization)
///   - MIDWORD   — token budget cut the output mid-word (clean-stop heuristic)
///
/// Plus per-case latency, so latency-focused changes (session reuse, prewarm, streaming) can be
/// measured with the same harness as quality-focused changes.
///
/// Gated behind the `RUN_FM_EVAL` compilation condition because it (a) needs the on-device model,
/// which CI runners do not have, and (b) is non-deterministic, so it is a local tuning tool rather
/// than a hard gate. xcodebuild does not forward shell env vars to the macOS test host, so a compile
/// flag (which *is* passable on the command line) is the reliable switch. CI never sets it — and
/// `tests.yml` also `-skip-testing`s this class — so it is a no-op there.
///
/// Run locally with:
///   xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
///     -only-testing:CotabbyTests/FoundationModelDriftEvalTests \
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_FM_EVAL' CODE_SIGNING_ALLOWED=NO
@available(macOS 26.0, *)
@MainActor
final class FoundationModelDriftEvalTests: XCTestCase {
#if RUN_FM_EVAL
    /// One scored scenario. Categories let per-category thresholds catch regressions that
    /// whole-set averages would smooth over.
    private struct EvalCase {
        enum Category: String, CaseIterable {
            case chatDrift     // chat-prone prefixes the chat-tuned model historically replied to
            case email         // mid-sentence business email writing
            case slack         // short informal team chat
            case code          // code-editor continuations (should produce code)
            case codeComment   // English inside source files
            case prose         // generic factual writing
            case midLine       // insertion with non-empty trailing text
        }

        let category: Category
        let prefix: String
        let trailing: String  // empty unless category == .midLine
    }

    /// Per-case scoring outcome, kept as a flat struct so the report renderer can iterate without
    /// re-running anything.
    private struct CaseOutcome {
        let scenario: EvalCase
        let drifted: Bool
        let empty: Bool
        let noise: Bool
        let midWord: Bool
        let normalized: String
        let raw: String
        let latency: TimeInterval
    }

    /// Historical chat-drift triggers: salutations, partial greetings, mid-thought stoppers that
    /// the chat-tuned model used to "reply" to instead of continuing.
    private static let chatDriftCases: [EvalCase] = [
        EvalCase(category: .chatDrift, prefix: "Hey Jacob, ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Hi Sarah,\n\n", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Thanks for ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "I wanted to reach out about ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Good morning team, ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Let me know if ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "lol yeah ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "The quarterly numbers are ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Please review the ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Hello! ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Dear hiring manager, ", trailing: ""),
        EvalCase(category: .chatDrift, prefix: "Cheers,\n", trailing: "")
    ]

    /// Mid-sentence email writing — the continuation should match tone and finish the thought,
    /// not start a reply.
    private static let emailCases: [EvalCase] = [
        EvalCase(category: .email, prefix: "Following up on our call yesterday, I wanted to ", trailing: ""),
        EvalCase(category: .email, prefix: "Per our discussion, the next step is to ", trailing: ""),
        EvalCase(category: .email, prefix: "Apologies for the delay, I was waiting on ", trailing: ""),
        EvalCase(category: .email, prefix: "Could you take a look at the attached and ", trailing: ""),
        EvalCase(category: .email, prefix: "I've reviewed the proposal and overall it ", trailing: ""),
        EvalCase(category: .email, prefix: "We're targeting end-of-quarter for the rollout, so ", trailing: ""),
        EvalCase(category: .email, prefix: "Looping in Priya from legal so she can ", trailing: ""),
        EvalCase(category: .email, prefix: "Happy to set up a call this week to ", trailing: "")
    ]

    /// Informal team chat — short, conversational, lowercase. The model should match the register.
    private static let slackCases: [EvalCase] = [
        EvalCase(category: .slack, prefix: "anyone seen the ", trailing: ""),
        EvalCase(category: .slack, prefix: "merging the fix now, can someone ", trailing: ""),
        EvalCase(category: .slack, prefix: "lunch at 1? thinking we ", trailing: ""),
        EvalCase(category: .slack, prefix: "wfh today, ping me on ", trailing: ""),
        EvalCase(category: .slack, prefix: "looks like CI is red again, probably ", trailing: ""),
        EvalCase(category: .slack, prefix: "btw the new design ", trailing: "")
    ]

    /// Code-editor prefixes — the model should output code, not prose. These are chosen so any
    /// plausible continuation is a well-formed code fragment.
    private static let codeCases: [EvalCase] = [
        EvalCase(category: .code, prefix: "def total(items):\n    return sum(", trailing: ""),
        EvalCase(category: .code, prefix: "let total = items.reduce(0, { $0 + ", trailing: ""),
        EvalCase(category: .code, prefix: "const sorted = items.sort((a, b) => a.priority - ", trailing: ""),
        EvalCase(category: .code, prefix: "if let value = dictionary[\"", trailing: ""),
        EvalCase(category: .code, prefix: "guard !text.isEmpty else { return ", trailing: ""),
        EvalCase(category: .code, prefix: "func fibonacci(_ n: Int) -> Int {\n    if n < 2 { return ", trailing: ""),
        EvalCase(category: .code, prefix: "try { await fetch(`/api/users/${", trailing: ""),
        EvalCase(category: .code, prefix: "SELECT name, email FROM users WHERE created_at > ", trailing: "")
    ]

    /// English inside source files — should still be writing about code, not breaking into chat.
    private static let codeCommentCases: [EvalCase] = [
        EvalCase(category: .codeComment, prefix: "// TODO: handle the case where the response is ", trailing: ""),
        EvalCase(category: .codeComment, prefix: "/// Returns the smallest positive integer that ", trailing: ""),
        EvalCase(category: .codeComment, prefix: "// This is a workaround for the bug in ", trailing: ""),
        EvalCase(category: .codeComment, prefix: "# This function expects a list of ", trailing: "")
    ]

    /// Generic factual prose — should stay factual, not break into chat or refusal.
    private static let proseCases: [EvalCase] = [
        EvalCase(category: .prose, prefix: "The Swift compiler enforces optionals because ", trailing: ""),
        EvalCase(category: .prose, prefix: "Apple's on-device language model runs ", trailing: ""),
        EvalCase(category: .prose, prefix: "Photosynthesis converts sunlight into ", trailing: ""),
        EvalCase(category: .prose, prefix: "Inflation is when the general price level ", trailing: ""),
        EvalCase(category: .prose, prefix: "In macOS, an accessibility element is ", trailing: ""),
        EvalCase(category: .prose, prefix: "The largest moon of Saturn is ", trailing: "")
    ]

    /// Mid-line insertion — non-empty trailing text. Today FM never sees the trailing context, so
    /// many of these will produce a continuation that does not bridge cleanly. PR 5 adds trailing
    /// context to the request; rerunning this bucket against PR 5 is the way to measure that gain.
    private static let midLineCases: [EvalCase] = [
        EvalCase(category: .midLine, prefix: "I'm flying to ", trailing: " on Friday."),
        EvalCase(category: .midLine, prefix: "The deadline is ", trailing: ", which gives us about a week."),
        EvalCase(category: .midLine, prefix: "Could you bring the ", trailing: " when you come by?"),
        EvalCase(category: .midLine, prefix: "Let's name the project ", trailing: ", that's catchy enough."),
        EvalCase(category: .midLine, prefix: "The CEO will be in ", trailing: " for the offsite next month."),
        EvalCase(category: .midLine, prefix: "for value in ", trailing: " {\n    process(value)\n}"),
        EvalCase(category: .midLine, prefix: "func parse(_ input: ", trailing: ") -> Result<Value, Error> {"),
        EvalCase(category: .midLine, prefix: "SELECT * FROM ", trailing: " WHERE id = ?")
    ]

    private static let allCases: [EvalCase] = chatDriftCases + emailCases + slackCases
        + codeCases + codeCommentCases + proseCases + midLineCases

    /// Phrases that mark a continuation as out-of-character. Matched case-insensitively anywhere
    /// in the output, so a continuation that mentions one inside a longer thought still flags.
    private static let driftTells: [String] = [
        "how are you", "how's it going", "hows it going", "hope you", "hope it", "hope this",
        "as an ai", "i'm here to", "i am here to", "let me know if you", "feel free to",
        "happy to help", "how can i help", "is there anything i", "i'd be happy", "i would be happy",
        // Assistant refusals / apologies — the model treating the prefix as a request to decline.
        "i'm sorry", "i am sorry", "i cannot assist", "i can't assist", "cannot assist with",
        "cannot help with", "unable to assist", "i cannot help", "i can't help"
    ]

    /// Chat-template or decoder residue. None should appear on the FM-only path, but having them in
    /// the rubric catches future routing regressions where the llama backend's output reaches the
    /// FM normalizer.
    private static let noiseMarkers: [String] = [
        "<|im_start|>", "<|im_end|>", "<think>", "</think>", "[INST]", "[/INST]"
    ]

    func test_reportEvalSuite() async throws {
        let availability = FoundationModelAvailabilityService()
        availability.refresh()
        try XCTSkipUnless(
            availability.isAvailable,
            "Apple Intelligence is unavailable here: \(availability.userVisibleMessage)"
        )

        let engine = FoundationModelSuggestionEngine(availabilityService: availability)

        var outcomes: [CaseOutcome] = []
        outcomes.reserveCapacity(Self.allCases.count)

        for scenario in Self.allCases {
            let request = CotabbyTestFixtures.suggestionRequest(
                prefixText: scenario.prefix,
                trailingText: scenario.trailing,
                maxPredictionTokens: 32
            )
            let start = Date()
            let result = try await engine.generateSuggestion(for: request)
            let elapsed = Date().timeIntervalSince(start)

            let normalized = result.text
            outcomes.append(
                CaseOutcome(
                    scenario: scenario,
                    drifted: Self.isDrift(prefix: scenario.prefix, output: normalized),
                    empty: normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    noise: Self.containsNoise(normalized) || Self.containsNoise(result.rawText),
                    midWord: Self.endsMidWord(normalized),
                    normalized: normalized,
                    raw: result.rawText,
                    latency: elapsed
                )
            )
        }

        let report = Self.renderReport(outcomes: outcomes)
        print(report)

        // Overall drift threshold stays permissive — we run this to track *trend*, not to gate CI.
        // 20% of cases (rounded down, floor of 3) gives the eval headroom for stochastic samples.
        let driftCount = outcomes.filter(\.drifted).count
        let driftCeiling = max(outcomes.count / 5, 3)
        XCTAssertLessThanOrEqual(
            driftCount,
            driftCeiling,
            "Too many out-of-character continuations.\n\(report)"
        )
        XCTAssertEqual(
            outcomes.filter(\.noise).count,
            0,
            "Chat-template residue leaked through.\n\(report)"
        )
        XCTAssertEqual(
            outcomes.filter(\.empty).count,
            0,
            "Some prompts returned empty after normalization.\n\(report)"
        )
    }

    private static func renderReport(outcomes: [CaseOutcome]) -> String {
        var lines = ["\n=== FM eval suite ==="]
        for (index, outcome) in outcomes.enumerated() {
            let tags = [
                outcome.drifted ? "DRIFT" : nil,
                outcome.empty ? "EMPTY" : nil,
                outcome.noise ? "NOISE" : nil,
                outcome.midWord ? "MIDWORD" : nil
            ].compactMap { $0 }
            let status = tags.isEmpty ? "ok" : tags.joined(separator: "+")
            let ms = Int((outcome.latency * 1000).rounded())
            lines.append("[\(index + 1)] \(outcome.scenario.category.rawValue) \(status) \(ms)ms")
            lines.append("    prefix=\(outcome.scenario.prefix.debugDescription)")
            if !outcome.scenario.trailing.isEmpty {
                lines.append("    trail =\(outcome.scenario.trailing.debugDescription)")
            }
            lines.append("    norm  =\(outcome.normalized.debugDescription)")
            lines.append("    raw   =\(outcome.raw.debugDescription)")
        }

        let categories = Set(outcomes.map(\.scenario.category)).sorted { $0.rawValue < $1.rawValue }
        lines.append("--- per-category ---")
        for category in categories {
            let bucket = outcomes.filter { $0.scenario.category == category }
            let drift = bucket.filter(\.drifted).count
            let midWord = bucket.filter(\.midWord).count
            lines.append(
                "\(category.rawValue): drift \(drift)/\(bucket.count), midword \(midWord)/\(bucket.count)"
            )
        }

        let latenciesMs = outcomes.map { Int(($0.latency * 1000).rounded()) }.sorted()
        if !latenciesMs.isEmpty {
            // Median: for an even-length sample average the two middle values, otherwise pick the
            // single middle. Reporting the upper-middle as "p50" would mask a small regression
            // sitting right at the median.
            let p50: Int
            if latenciesMs.count.isMultiple(of: 2) {
                let mid = latenciesMs.count / 2
                p50 = (latenciesMs[mid - 1] + latenciesMs[mid]) / 2
            } else {
                p50 = latenciesMs[latenciesMs.count / 2]
            }
            // Nearest-rank: ceil(0.95 * n) gives the 1-indexed rank, so subtract 1 for the array
            // index. Plain truncation overshoots for small per-category buckets.
            let rank = Int((Double(latenciesMs.count) * 0.95).rounded(.up))
            let p95Index = min(latenciesMs.count - 1, max(0, rank - 1))
            let p95 = latenciesMs[p95Index]
            lines.append("--- latency (ms) ---")
            lines.append("p50=\(p50), p95=\(p95), max=\(latenciesMs.last ?? 0)")
        }

        let driftTotal = outcomes.filter(\.drifted).count
        let midWordTotal = outcomes.filter(\.midWord).count
        let emptyTotal = outcomes.filter(\.empty).count
        let noiseTotal = outcomes.filter(\.noise).count
        lines.append(
            "TOTAL: \(outcomes.count) cases, drift=\(driftTotal), "
                + "midword=\(midWordTotal), empty=\(emptyTotal), noise=\(noiseTotal)"
        )
        return lines.joined(separator: "\n")
    }

    /// A continuation drifts if it contains an assistant tell, or opens with a greeting word that
    /// the prefix had not already started (so finishing "Hi Sa…" → "rah" is fine, but a bare
    /// "Hi there" after a mid-sentence prefix is drift).
    private static func isDrift(prefix: String, output: String) -> Bool {
        let lower = output.lowercased()
        if driftTells.contains(where: { lower.contains($0) }) {
            return true
        }

        // Greeting openers only — "thanks" is omitted because continuing the user's own message
        // with a thank-you ("Hey Jacob, " -> "thanks for the update") is correct, not drift.
        let openers = ["hi ", "hey ", "hello", "dear ", "good morning", "good afternoon"]
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLower = prefix.lowercased()
        return openers.contains { opener in
            trimmed.hasPrefix(opener) && !prefixLower.contains(opener)
        }
    }

    private static func containsNoise(_ text: String) -> Bool {
        noiseMarkers.contains { text.contains($0) }
    }

    /// Heuristic for "the token budget cut the model off mid-word". Empty strings are exempt
    /// (counted under `empty`). A clean stop is sentence-ending punctuation or a closing bracket
    /// / paren that finishes a code fragment. Trimming above strips any trailing whitespace, so a
    /// whitespace check here would be dead code.
    private static func endsMidWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return false
        }
        if last.isPunctuation { return false }
        if "})]>".contains(last) { return false }
        return true
    }
#else
    func test_reportEvalSuite() throws {
        throw XCTSkip(
            "Live FM eval is local-only. Run with "
                + "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_FM_EVAL' (see file header)."
        )
    }
#endif
}

#endif
