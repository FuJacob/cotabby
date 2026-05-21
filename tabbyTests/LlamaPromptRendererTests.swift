import CoreGraphics
import XCTest
@testable import tabby

/// Tests for the prompt-rendering boundary between DECIDE and GENERATE.
///
/// These are pure-function tests — no mocks, no I/O. The whole point of
/// LlamaPromptRenderer is that given the same inputs, it returns the exact
/// same string, so every assertion here is deterministic.
final class LlamaPromptRendererTests: XCTestCase {

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

    // MARK: - instruction prompt

    /// The structural contract for local instruct models: stable task rules first, supporting
    /// context in the middle, then a late length cue right before the prefix the model must
    /// continue. Losing one of these sections tends to degrade prompt-following without throwing.
    func test_instructionPrompt_containsTaskScreenContextAndFinalInstruction() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Messages",
            completionLengthInstruction: "Keep completion short.",
            userName: nil,
            userTags: nil
        )

        XCTAssertTrue(prompt.contains("Task:"), "instruction prompt should include Task section")
        XCTAssertTrue(
            prompt.contains("Screen context:"),
            "instruction prompt should include Screen context section"
        )
        XCTAssertTrue(
            prompt.contains("Final instruction:"),
            "instruction prompt should include a late final instruction section"
        )
        XCTAssertTrue(prompt.contains("Text before caret:"), "instruction prompt should include the prefix header")
    }

    func test_instructionPrompt_includesApplicationNameAndPrefix() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "My prefix text here",
            applicationName: "Slack",
            completionLengthInstruction: "Short.",
            userName: nil,
            userTags: nil
        )

        XCTAssertTrue(prompt.contains("App: Slack"))
        XCTAssertTrue(prompt.contains("My prefix text here"))
    }

    /// The completion-length instruction is chosen from the user's word-count
    /// preset. It must reach the prompt verbatim so the model sees the exact
    /// guidance the UI showed the user.
    func test_instructionPrompt_includesCompletionLengthInstructionNearPrefix() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX_BODY_XYZ",
            applicationName: "App",
            completionLengthInstruction: "UNIQUE_LENGTH_MARKER_7_TO_12_WORDS",
            userName: nil,
            userTags: nil
        )

        XCTAssertTrue(prompt.contains("UNIQUE_LENGTH_MARKER_7_TO_12_WORDS"))

        guard let finalInstructionRange = prompt.range(of: "Final instruction:"),
              let lengthRange = prompt.range(of: "UNIQUE_LENGTH_MARKER_7_TO_12_WORDS"),
              let prefixRange = prompt.range(of: "PREFIX_BODY_XYZ") else {
            XCTFail("Expected final instruction header, length marker, and prefix in the prompt")
            return
        }

        XCTAssertLessThan(finalInstructionRange.lowerBound, lengthRange.lowerBound)
        XCTAssertLessThan(lengthRange.lowerBound, prefixRange.lowerBound)
    }

    func test_instructionPrompt_includesProfileContextWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "x",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: "UNIQUE_NAME_MARKER_ZQRT",
            userTags: ["UNIQUE_TAG_MARKER"]
        )

        XCTAssertTrue(prompt.contains("UNIQUE_NAME_MARKER_ZQRT"),
                      "instruction prompt should carry user-provided profile name")
        // userTags emission is intentionally disabled in LlamaPromptRenderer
        // (see TODO in that file); the tag string must not leak into the prompt today.
        XCTAssertFalse(prompt.contains("UNIQUE_TAG_MARKER"),
                       "instruction prompt should not carry user-provided profile tags while the feature is gated off")
    }

    /// The prefix remains the last payload in the prompt so the model still ends on the actual
    /// text it must continue, even though the length cue is moved later in the prompt.
    func test_instructionPrompt_prefixAppearsAfterScreenContextAndEndsPrompt() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX_BODY_XYZ",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            userTags: nil
        )

        guard let contextRange = prompt.range(of: "Screen context:"),
              let prefixRange = prompt.range(of: "PREFIX_BODY_XYZ") else {
            XCTFail("Expected both Screen context: and PREFIX_BODY_XYZ in the prompt")
            return
        }

        XCTAssertLessThan(contextRange.lowerBound, prefixRange.lowerBound,
                          "prefix must appear after the Screen context header")
        XCTAssertTrue(prompt.hasSuffix("PREFIX_BODY_XYZ"))
    }

    func test_instructionPrompt_includesVisualContextSummaryWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            userTags: nil,
            visualContextSummary: "A window describing a cat."
        )

        XCTAssertTrue(prompt.contains("Screen content:"))
        XCTAssertTrue(prompt.contains("A window describing a cat."))
    }

    func test_instructionPrompt_includesClipboardContextWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            userTags: nil,
            clipboardContext: "UNIQUE_CLIPBOARD_MARKER"
        )

        XCTAssertTrue(prompt.contains("User's clipboard:"))
        XCTAssertTrue(prompt.contains("UNIQUE_CLIPBOARD_MARKER"))
    }

    func test_instructionPrompt_omitsVisualContextSummaryWhenNil() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            userTags: nil,
            visualContextSummary: nil
        )

        XCTAssertFalse(prompt.contains("Screen content:"))
    }

    private func makeRequest(
        prompt: String,
        elementIdentifier: String = "field",
        topK: Int = 20,
        inputFrameRect: CGRect? = nil
    ) -> SuggestionRequest {
        let snapshot = FocusedInputSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.example.TestApp",
            processIdentifier: 123,
            elementIdentifier: elementIdentifier,
            role: "AXTextField",
            subrole: nil,
            caretRect: .zero,
            inputFrameRect: inputFrameRect,
            caretSource: "test",
            caretQuality: .exact,
            observedCharWidth: nil,
            precedingText: prompt,
            trailingText: "",
            selection: NSRange(location: prompt.count, length: 0),
            isSecure: false
        )
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)

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
            userTags: nil,
            clipboardContext: nil,
            visualContextSummary: nil
        )
    }
}
