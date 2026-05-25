import XCTest
@testable import Cotabby

#if canImport(FoundationModels)

/// Live Apple Intelligence drift eval — deliberately NOT a CI test.
///
/// Apple's system model is chat-tuned and used to break character on plain prefixes: greeting the
/// user ("Jacob, how are you"), tacking on pleasantries ("Hope it's going well"), or replying like
/// an assistant. This harness runs real on-device generations against the prefixes that historically
/// drifted and reports how many still do, so prompt changes can be measured instead of guessed at.
///
/// It is gated behind the `RUN_FM_EVAL` compilation condition because it (a) needs the on-device
/// model, which CI runners do not have, and (b) is non-deterministic, so it is a local tuning tool
/// rather than a hard gate. xcodebuild does not forward shell env vars to the macOS test host, so a
/// compile flag (which *is* passable on the command line) is the reliable switch. CI never sets it
/// — and `tests.yml` also `-skip-testing`s this class — so it is a no-op there.
///
/// Run locally with:
///   xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
///     -only-testing:CotabbyTests/FoundationModelDriftEvalTests \
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_FM_EVAL' CODE_SIGNING_ALLOWED=NO
@available(macOS 26.0, *)
@MainActor
final class FoundationModelDriftEvalTests: XCTestCase {
#if RUN_FM_EVAL
    /// Prefixes that previously pulled the model into assistant/chat replies. Each ends mid-thought,
    /// where the correct behavior is to keep typing, not to greet or reply.
    private static let cases: [String] = [
        "Hey Jacob, ",
        "Hi Sarah,\n\n",
        "Thanks for ",
        "I wanted to reach out about ",
        "Good morning team, ",
        "Let me know if ",
        "lol yeah ",
        "The quarterly numbers are ",
        "Please review the ",
        "Hello! "
    ]

    /// Phrases that mark a continuation as out-of-character: assistant replies, greetings, or the
    /// pleasantries the user flagged. Matched case-insensitively anywhere in the output.
    private static let driftTells: [String] = [
        "how are you", "how's it going", "hows it going", "hope you", "hope it", "hope this",
        "as an ai", "i'm here to", "i am here to", "let me know if you", "feel free to",
        "happy to help", "how can i help", "is there anything i", "i'd be happy", "i would be happy",
        // Assistant refusals / apologies — the model treating the prefix as a request to decline.
        "i'm sorry", "i am sorry", "i cannot assist", "i can't assist", "cannot assist with",
        "cannot help with", "unable to assist", "i cannot help", "i can't help"
    ]

    func test_reportAssistantDriftRate() async throws {
        let availability = FoundationModelAvailabilityService()
        availability.refresh()
        try XCTSkipUnless(
            availability.isAvailable,
            "Apple Intelligence is unavailable here: \(availability.userVisibleMessage)"
        )

        let engine = FoundationModelSuggestionEngine(availabilityService: availability)

        var driftCount = 0
        var report = "\n=== FM drift eval ===\n"
        for (index, prefix) in Self.cases.enumerated() {
            let request = CotabbyTestFixtures.suggestionRequest(
                prefixText: prefix,
                maxPredictionTokens: 32
            )
            let result = try await engine.generateSuggestion(for: request)
            let drifted = Self.isDrift(prefix: prefix, output: result.text)
            if drifted { driftCount += 1 }
            report += "[\(index + 1)] \(drifted ? "DRIFT" : "ok   ") prefix=\(prefix.debugDescription)\n"
            report += "        norm=\(result.text.debugDescription)\n"
            report += "        raw =\(result.rawText.debugDescription)\n"
        }
        report += "drift: \(driftCount)/\(Self.cases.count)\n"
        print(report)

        XCTAssertLessThanOrEqual(
            driftCount,
            2,
            "Too many out-of-character continuations.\(report)"
        )
    }

    /// A continuation drifts if it contains an assistant tell, or opens with a greeting word that the
    /// prefix had not already started (so finishing "Hi Sa…" → "rah" is fine, but a bare "Hi there"
    /// after a mid-sentence prefix is drift).
    private static func isDrift(prefix: String, output: String) -> Bool {
        let lower = output.lowercased()
        if driftTells.contains(where: { lower.contains($0) }) {
            return true
        }

        // Greeting openers only — "thanks" is omitted because continuing the user's own message with
        // a thank-you ("Hey Jacob, " -> "thanks for the update") is correct, not assistant drift.
        let openers = ["hi ", "hey ", "hello", "dear ", "good morning", "good afternoon"]
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixLower = prefix.lowercased()
        return openers.contains { opener in
            trimmed.hasPrefix(opener) && !prefixLower.contains(opener)
        }
    }
#else
    func test_reportAssistantDriftRate() throws {
        throw XCTSkip(
            "Live FM eval is local-only. Run with "
                + "SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_FM_EVAL' (see file header)."
        )
    }
#endif
}

#endif
