import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for `LlamaPromptCacheHintTracker`, the conservative byte-prefix hint the llama engine
/// passes into the runtime to reuse KV state across keystrokes. Pure-function and deterministic:
/// the tracker only advertises reuse for the same focused field and sampling fingerprint.
final class LlamaPromptCacheHintTrackerTests: XCTestCase {

    // MARK: - cache hints

    func test_cacheHint_nilBeforeSuccessfulRequestIsRecorded() {
        var tracker = LlamaPromptCacheHintTracker()

        XCTAssertNil(tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello")))
    }

    func test_cacheHint_returnsCommonPrefixBytesForSameFocusedField() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(makeRequest(prompt: "hello"))

        XCTAssertEqual(
            tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello!")),
            "hello".utf8.count
        )
    }

    func test_cacheHint_invalidatesWhenFocusedFieldChanges() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(makeRequest(prompt: "hello", elementIdentifier: "field-a"))

        XCTAssertNil(
            tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello!", elementIdentifier: "field-b"))
        )
    }

    func test_cacheHint_prefersStableInputFrameOverUnstableElementIdentifier() {
        var tracker = LlamaPromptCacheHintTracker()
        let fieldFrame = CGRect(x: 10, y: 20, width: 300, height: 44)
        tracker.recordSuccessfulRequest(
            makeRequest(prompt: "hello", elementIdentifier: "field-a", inputFrameRect: fieldFrame)
        )

        XCTAssertEqual(
            tracker.cachedPrefixBytes(
                for: makeRequest(prompt: "hello!", elementIdentifier: "field-b", inputFrameRect: fieldFrame)
            ),
            "hello".utf8.count
        )
    }

    func test_cacheHint_invalidatesWhenSamplingFingerprintChanges() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(makeRequest(prompt: "hello", topK: 20))

        XCTAssertNil(tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello!", topK: 40)))
    }

    func test_cacheHint_invalidatesWhenProcessChanges() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(makeRequest(prompt: "hello", processIdentifier: 100))

        XCTAssertNil(tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello!", processIdentifier: 200)))
    }

    /// A mismatch forgets the recorded prompt entirely, so returning to the original field cannot
    /// advertise reuse of a native sequence that the other field's generation has since replaced.
    func test_cacheHint_mismatchForgetsTheRecordedPrompt() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(makeRequest(prompt: "hello", elementIdentifier: "field-a"))

        XCTAssertNil(tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello", elementIdentifier: "field-b")))
        XCTAssertNil(tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello!", elementIdentifier: "field-a")))
    }

    func test_cacheHint_resetForgetsTheRecordedPrompt() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(makeRequest(prompt: "hello"))
        tracker.reset()

        XCTAssertNil(tracker.cachedPrefixBytes(for: makeRequest(prompt: "hello!")))
    }

    func test_cacheHint_toleratesSubPointInputFrameJitter() {
        var tracker = LlamaPromptCacheHintTracker()
        tracker.recordSuccessfulRequest(
            makeRequest(prompt: "hello", inputFrameRect: CGRect(x: 10.2, y: 20.4, width: 300.3, height: 44.1))
        )

        XCTAssertEqual(
            tracker.cachedPrefixBytes(
                for: makeRequest(prompt: "hello!", inputFrameRect: CGRect(x: 9.8, y: 19.6, width: 299.7, height: 43.9))
            ),
            5
        )
    }

    /// The hint is a UTF-8 byte count of the shared prefix: zero (not nil) when nothing is shared,
    /// bounded by the shorter prompt, and counted in bytes for multi-byte characters.
    func test_cacheHint_countsSharedUTF8PrefixBytes() {
        let cases: [(recorded: String, next: String, expected: Int)] = [
            ("hello", "world", 0),
            ("hello world", "hello", 5),
            ("café", "café au lait", "café".utf8.count),
            ("naïve", "naive", 2)
        ]

        for testCase in cases {
            var tracker = LlamaPromptCacheHintTracker()
            tracker.recordSuccessfulRequest(makeRequest(prompt: testCase.recorded))
            XCTAssertEqual(
                tracker.cachedPrefixBytes(for: makeRequest(prompt: testCase.next)),
                testCase.expected,
                "\(testCase.recorded) -> \(testCase.next)"
            )
        }
    }

    // MARK: - helpers

    private func makeRequest(
        prompt: String,
        elementIdentifier: String = "field",
        processIdentifier: Int32 = 123,
        topK: Int = 20,
        inputFrameRect: CGRect? = nil
    ) -> SuggestionRequest {
        let context = CotabbyTestFixtures.focusedInputContext(
            processIdentifier: processIdentifier,
            elementIdentifier: elementIdentifier,
            inputFrameRect: inputFrameRect,
            precedingText: prompt
        )

        return SuggestionRequest(
            context: context,
            prefixText: prompt,
            prompt: prompt,
            generation: context.generation,
            maxPredictionTokens: 8,
            temperature: 0.1,
            topK: topK,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxSuffixCharacters: 192,
            completionLengthInstruction: "Return only the next few words.",
            userName: nil,
            customRules: [],
            languageInstruction: nil,
            clipboardContext: nil,
            visualContextSummary: nil,
            isMultiLineEnabled: false
        )
    }
}
