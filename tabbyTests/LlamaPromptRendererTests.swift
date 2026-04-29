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

    /// The structural contract of the instruction prompt: three labelled sections the
    /// instruct model is trained to parse. Losing any of them would silently
    /// degrade output quality without throwing.
    func test_instructionPrompt_containsTaskAndOutputContract() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Messages",
            completionLengthInstruction: "Keep completion short.",
            customAIInstructions: nil
        )

        XCTAssertTrue(prompt.contains("Task:"), "instruction prompt should include Task section")
        XCTAssertTrue(
            prompt.contains("Output contract:"),
            "instruction prompt should include Output contract section"
        )
        XCTAssertTrue(prompt.contains("Context:"), "instruction prompt should include Context section")
    }

    func test_instructionPrompt_includesApplicationNameAndPrefix() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "My prefix text here",
            applicationName: "Slack",
            completionLengthInstruction: "Short.",
            customAIInstructions: nil
        )

        XCTAssertTrue(prompt.contains("App: Slack"))
        XCTAssertTrue(prompt.contains("My prefix text here"))
    }

    /// The completion-length instruction is chosen from the user's word-count
    /// preset. It must reach the prompt verbatim so the model sees the exact
    /// guidance the UI showed the user.
    func test_instructionPrompt_includesCompletionLengthInstruction() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "x",
            applicationName: "App",
            completionLengthInstruction: "UNIQUE_LENGTH_MARKER_7_TO_12_WORDS",
            customAIInstructions: nil
        )

        XCTAssertTrue(prompt.contains("UNIQUE_LENGTH_MARKER_7_TO_12_WORDS"))
    }

    func test_instructionPrompt_includesCustomInstructionsWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "x",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            customAIInstructions: "UNIQUE_CUSTOM_MARKER_ZQRT"
        )

        XCTAssertTrue(prompt.contains("UNIQUE_CUSTOM_MARKER_ZQRT"),
                      "instruction prompt should carry user-provided custom instructions")
    }

    /// The prefix is always the *last* section of the instruction prompt — the model
    /// continues from the last token, so the prefix has to come last.
    /// Tests the contract that prefix comes after Context:/App:/Text before caret:.
    func test_instructionPrompt_prefixAppearsAfterContextHeader() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX_BODY_XYZ",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            customAIInstructions: nil
        )

        guard let contextRange = prompt.range(of: "Context:"),
              let prefixRange = prompt.range(of: "PREFIX_BODY_XYZ") else {
            XCTFail("Expected both Context: and PREFIX_BODY_XYZ in the prompt")
            return
        }

        XCTAssertLessThan(contextRange.lowerBound, prefixRange.lowerBound,
                          "prefix must appear after the Context: header")
    }

    func test_instructionPrompt_includesVisualContextSummaryWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            customAIInstructions: nil,
            visualContextSummary: "A window describing a cat."
        )

        XCTAssertTrue(prompt.contains("Screen content:"))
        XCTAssertTrue(prompt.contains("A window describing a cat."))
    }

    func test_instructionPrompt_omitsVisualContextSummaryWhenNil() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            customAIInstructions: nil,
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
            customAIInstructions: nil,
            visualContextSummary: nil
        )
    }
}
