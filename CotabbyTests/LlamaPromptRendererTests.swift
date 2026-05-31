import CoreGraphics
import XCTest
@testable import Cotabby

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

    /// The prose contract for the raw single-string prompt: autocomplete rules, then context as
    /// sentences, then the bare prefix as the final payload. No standalone `Label:` lines (the
    /// thing small models echo into ghost text), and the prefix stays last so the model continues
    /// from where the user stopped.
    func test_instructionPrompt_carriesAutocompleteRulesAndAppContextAsProse() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Messages",
            completionLengthInstruction: "Keep completion short.",
            userName: nil
        )

        XCTAssertTrue(prompt.contains("autocomplete, not chat"))
        XCTAssertTrue(prompt.contains("writing in Messages"))
    }

    /// No standalone `Label:` line may appear, even with every context block populated — those are
    /// exactly what small instruct models parrot back as ghost text.
    func test_instructionPrompt_containsNoLabelScaffolding() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Messages",
            completionLengthInstruction: "Keep completion short.",
            userName: "Jacob",
            customRules: ["Be concise"],
            languageInstruction: "Respond in German.",
            clipboardContext: "clip",
            visualContextSummary: "a form"
        )

        XCTAssertFalse(prompt.contains("Task:"))
        XCTAssertFalse(prompt.contains("Screen context:"))
        XCTAssertFalse(prompt.contains("Screen content:"))
        XCTAssertFalse(prompt.contains("Final instruction:"))
        XCTAssertFalse(prompt.contains("Text before caret:"))
        XCTAssertFalse(prompt.contains("User Profile Context:"))
        XCTAssertFalse(prompt.contains("Your style preferences:"))
        XCTAssertFalse(prompt.contains("User's clipboard:"))
    }

    func test_instructionPrompt_includesApplicationNameAndPrefix() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "My prefix text here",
            applicationName: "Slack",
            completionLengthInstruction: "Short.",
            userName: nil
        )

        XCTAssertTrue(prompt.contains("writing in Slack"))
        XCTAssertTrue(prompt.contains("My prefix text here"))
    }

    /// Length is enforced by the token budget, not by an in-prompt word range, so the
    /// completion-length cue must never reach the local-model prompt even if a caller passes one.
    func test_instructionPrompt_omitsCompletionLengthInstruction() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX_BODY_XYZ",
            applicationName: "App",
            completionLengthInstruction: "UNIQUE_LENGTH_MARKER_7_TO_12_WORDS",
            userName: nil
        )

        XCTAssertFalse(prompt.contains("UNIQUE_LENGTH_MARKER_7_TO_12_WORDS"))
        // The prefix is still the last payload regardless.
        XCTAssertTrue(prompt.hasSuffix("PREFIX_BODY_XYZ"))
    }

    func test_instructionPrompt_includesProfileContextWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "x",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: "UNIQUE_NAME_MARKER_ZQRT"
        )

        XCTAssertTrue(prompt.contains("UNIQUE_NAME_MARKER_ZQRT"),
                      "instruction prompt should carry user-provided profile name")
    }

    /// The prefix remains the last payload in the prompt so the model ends on the actual text it
    /// must continue. This is the one structural invariant the prose rewrite must preserve.
    func test_instructionPrompt_prefixAppearsAfterContextAndEndsPrompt() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX_BODY_XYZ",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil
        )

        guard let contextRange = prompt.range(of: "writing in App"),
              let prefixRange = prompt.range(of: "PREFIX_BODY_XYZ") else {
            XCTFail("Expected both the app-context sentence and PREFIX_BODY_XYZ in the prompt")
            return
        }

        XCTAssertLessThan(contextRange.lowerBound, prefixRange.lowerBound,
                          "prefix must appear after the app-context sentence")
        XCTAssertTrue(prompt.hasSuffix("PREFIX_BODY_XYZ"))
    }

    func test_instructionPrompt_includesVisualContextSummaryWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            visualContextSummary: "A window describing a cat."
        )

        XCTAssertTrue(prompt.contains("Nearby on screen, the user can see"))
        XCTAssertTrue(prompt.contains("A window describing a cat."))
    }

    func test_instructionPrompt_includesClipboardContextWhenProvided() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            clipboardContext: "UNIQUE_CLIPBOARD_MARKER"
        )

        XCTAssertTrue(prompt.contains("clipboard currently contains"))
        XCTAssertTrue(prompt.contains("UNIQUE_CLIPBOARD_MARKER"))
    }

    func test_instructionPrompt_omitsVisualContextSummaryWhenNil() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "PREFIX",
            applicationName: "App",
            completionLengthInstruction: "Short.",
            userName: nil,
            visualContextSummary: nil
        )

        XCTAssertFalse(prompt.contains("Nearby on screen"))
    }

    // MARK: - messages() chat-template path
    //
    // The chat-template path (used when the model ships a template) splits the prompt into a
    // system turn (rules + context) and a user turn (the bare prefix). These tests guard the
    // invariant that fixes the prompt-scaffolding echo bug: the user turn must be exactly the
    // text to continue, with none of the "Text before caret:" / "Task:" labels that small
    // instruct models were parroting back into the ghost text.

    func test_messages_userTurnIsExactlyThePrefixWithNoScaffolding() {
        let chat = LlamaPromptRenderer.messages(
            prefixText: "I was just about to",
            applicationName: "TextEdit",
            completionLengthInstruction: "Return only the next 3 to 7 words.",
            userName: nil,
            customRules: []
        )

        XCTAssertEqual(chat.user, "I was just about to")
    }

    func test_messages_systemTurnDropsRawLabelScaffolding() {
        let chat = LlamaPromptRenderer.messages(
            prefixText: "hello",
            applicationName: "TextEdit",
            completionLengthInstruction: "",
            userName: nil,
            customRules: []
        )

        XCTAssertFalse(chat.system.contains("Text before caret:"))
        XCTAssertFalse(chat.system.contains("Final instruction:"))
    }

    func test_messages_systemTurnDoesNotContainThePrefix() {
        let chat = LlamaPromptRenderer.messages(
            prefixText: "Zxqv distinctive prefix marker",
            applicationName: "TextEdit",
            completionLengthInstruction: "",
            userName: nil,
            customRules: []
        )

        XCTAssertFalse(chat.system.contains("Zxqv distinctive prefix marker"))
    }

    func test_messages_systemTurnCarriesAutocompleteRules() {
        let chat = LlamaPromptRenderer.messages(
            prefixText: "x",
            applicationName: "TextEdit",
            completionLengthInstruction: "",
            userName: nil,
            customRules: []
        )

        XCTAssertTrue(chat.system.contains("autocomplete, not chat"))
        // App context is now prose ("The user is writing in TextEdit."), not a "Screen context:"
        // label block — but the application name itself must still be present.
        XCTAssertTrue(chat.system.contains("writing in TextEdit"))
    }

    func test_messages_systemTurnIncludesProfileRulesContextWhenProvided() {
        let chat = LlamaPromptRenderer.messages(
            prefixText: "x",
            applicationName: "TextEdit",
            completionLengthInstruction: "",
            userName: "Jacob",
            customRules: ["Always be concise"],
            languageInstruction: "Respond in German.",
            clipboardContext: "copied text",
            visualContextSummary: "a login form"
        )

        XCTAssertTrue(chat.system.contains("Jacob"))
        XCTAssertTrue(chat.system.contains("Always be concise"))
        XCTAssertTrue(chat.system.contains("Respond in German."))
        XCTAssertTrue(chat.system.contains("copied text"))
        XCTAssertTrue(chat.system.contains("a login form"))

        // The prose invariant: even with every context block populated, the system turn must carry
        // no standalone "Label:" lines — those are exactly what small models echoed into ghost text.
        XCTAssertFalse(chat.system.contains("User Profile Context:"))
        XCTAssertFalse(chat.system.contains("Your style preferences:"))
        XCTAssertFalse(chat.system.contains("Screen context:"))
        XCTAssertFalse(chat.system.contains("Screen content:"))
        XCTAssertFalse(chat.system.contains("User's clipboard:"))
    }

    func test_messages_omitsOptionalContextWhenAbsent() {
        let chat = LlamaPromptRenderer.messages(
            prefixText: "x",
            applicationName: "TextEdit",
            completionLengthInstruction: "",
            userName: nil,
            customRules: [],
            clipboardContext: nil,
            visualContextSummary: nil
        )

        // Assert the optional *content blocks* are absent, not rule words: the base rules always
        // mention "clipboard" ("Use clipboard or screen context only when it directly helps"), so
        // the block header "User's clipboard:" is the correct absence check.
        XCTAssertFalse(chat.system.contains("User's clipboard:"))
        XCTAssertFalse(chat.system.contains("Screen content:"))
        XCTAssertFalse(chat.system.contains("User Profile Context:"))
        XCTAssertFalse(chat.system.contains("Your style preferences:"))
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
            customRules: [],
            languageInstruction: nil,
            clipboardContext: nil,
            visualContextSummary: nil,
            isMultiLineEnabled: false
        )
    }
}
