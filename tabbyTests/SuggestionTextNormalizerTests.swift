import XCTest
@testable import tabby

/// Tests for the final cleanup layer shared by every suggestion backend.
///
/// The normalizer is deliberately backend-agnostic: llama.cpp and Foundation Models can both echo
/// prompt text, add template markers, or return multi-line completions. These tests lock down the
/// UI-facing contract that only one usable inline continuation reaches the overlay.
final class SuggestionTextNormalizerTests: XCTestCase {
    func test_normalize_removesChatTemplateMarkersAndPromptEcho() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "Hello",
            prompt: "PROMPT_PAYLOAD",
            precedingText: "Hello"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "PROMPT_PAYLOAD<|im_start|> useful continuation<|im_end|>",
            for: request
        )

        XCTAssertEqual(normalized, " useful continuation")
    }

    func test_normalize_removesPrefixEchoWhenPromptWasNotEchoed() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "Hello world",
            prompt: "SHORT_APPLE_PROMPT",
            precedingText: "Hello world"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "Hello world, with a small addition",
            for: request
        )

        XCTAssertEqual(normalized, ", with a small addition")
    }

    func test_normalize_removesBackendSpecificPromptEchoCandidate() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "Hello world",
            prompt: "LLAMA_PROMPT",
            precedingText: "Hello world"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "APPLE_PROMPT\n useful continuation",
            for: request,
            promptEchoCandidates: ["APPLE_PROMPT"]
        )

        XCTAssertEqual(normalized, " useful continuation")
    }

    func test_normalize_trimsLeadingFormattingNewlinesBeforeTakingFirstLine() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "Hello")

        let normalized = SuggestionTextNormalizer.normalize(
            "\n\nnext words only\nsecond paragraph should be dropped",
            for: request
        )

        XCTAssertEqual(normalized, "next words only")
    }

    func test_normalize_dropsSuggestionThatRepeatsTrailingTextAfterCaret() {
        let request = TabbyTestFixtures.suggestionRequest(
            precedingText: "Hello",
            trailingText: " existing suffix"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " existing suffix and extra generated text",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_stripsModelLeadingWhitespaceWhenPrecedingTextAlreadyEndsWithWhitespace() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "Hello ")

        let normalized = SuggestionTextNormalizer.normalize(" world", for: request)

        XCTAssertEqual(normalized, "world")
    }

    func test_normalize_preservesModelLeadingWhitespaceWhenPrecedingTextNeedsWordBoundary() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "Hello")

        let normalized = SuggestionTextNormalizer.normalize(" world", for: request)

        XCTAssertEqual(normalized, " world")
    }

    func test_normalize_stripsRepeatedPrecedingTailAcrossMultipleWords() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "hi i like")

        let normalized = SuggestionTextNormalizer.normalize(
            "I like matcha in the morning",
            for: request
        )

        XCTAssertEqual(normalized, " matcha in the morning")
    }

    func test_normalize_preservesWordBoundaryAfterStrippingEchoedTailWord() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "stuff like this",
            precedingText: "stuff like this"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "this Text Okay",
            for: request
        )

        XCTAssertEqual(normalized, " Text Okay")
    }

    func test_normalize_repairsMissingSpaceBeforeTitleCaseSuggestion() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "stuff like this",
            precedingText: "stuff like this"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "Text Okay",
            for: request
        )

        XCTAssertEqual(normalized, " Text Okay")
    }

    func test_normalize_stripsAlreadyTypedPrefixFromWholeWordCompletion() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "so what else have you been doing for the lasdt 30 minu",
            precedingText: "so what else have you been doing for the lasdt 30 minu"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "minutes?",
            for: request
        )

        XCTAssertEqual(normalized, "tes?")
    }

    func test_normalize_dropsSingleLetterTailFromWholeWordCompletion() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "I am now testing the app to see if it is any bette",
            precedingText: "I am now testing the app to see if it is any bette"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "better",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_stripsAlreadyTypedPrefixFromWholePhraseCompletion() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "I will check the docum",
            precedingText: "I will check the docum"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "document tomorrow",
            for: request
        )

        XCTAssertEqual(normalized, "ent tomorrow")
    }

    func test_normalize_returnsEmptyWhenSuggestionIsOnlyAnEchoedTailWord() {
        let request = TabbyTestFixtures.suggestionRequest(precedingText: "hello world")

        let normalized = SuggestionTextNormalizer.normalize("world", for: request)

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_dropsLowValueGenericQuestionCompletion() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "I am now testing this. What should I",
            precedingText: "I am now testing this. What should I"
        )

        let normalized = SuggestionTextNormalizer.normalize(" be doing.", for: request)

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsConcreteContinuationEvenWhenShort() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "Ask Priya about",
            precedingText: "Ask Priya about",
            fieldContextText: "Aurora launch review\nCustomer timeline"
        )

        let normalized = SuggestionTextNormalizer.normalize(" the timeline", for: request)

        XCTAssertEqual(normalized, " the timeline")
    }

    func test_normalize_dropsStandaloneRelativeTimestampCopiedFromUI() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "much better results",
            precedingText: "much better results",
            fieldContextText: "Copy\n23h\nLike"
        )

        let normalized = SuggestionTextNormalizer.normalize(" 23h", for: request)

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_dropsStandaloneParenthesizedTimestampCopiedFromUI() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "much better results",
            precedingText: "much better results",
            fieldContextText: "Copy\n23 hrs\nReply"
        )

        let normalized = SuggestionTextNormalizer.normalize(" (23 hrs)", for: request)

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsShortNaturalDurationPhrases() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "The drive",
            precedingText: "The drive"
        )

        XCTAssertEqual(
            SuggestionTextNormalizer.normalize(" takes 2 hours", for: request),
            " takes 2 hours"
        )
        XCTAssertEqual(
            SuggestionTextNormalizer.normalize(" in 3 days", for: request),
            " in 3 days"
        )
        XCTAssertEqual(
            SuggestionTextNormalizer.normalize(" after 10 minutes", for: request),
            " after 10 minutes"
        )
    }

    func test_normalize_keepsNaturalDurationPhraseWhenItHasDraftMeaning() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "The benchmark recovered",
            precedingText: "The benchmark recovered"
        )

        let normalized = SuggestionTextNormalizer.normalize(" after 23 hours of testing", for: request)

        XCTAssertEqual(normalized, " after 23 hours of testing")
    }

    func test_normalize_dropsOCRCorruptedWordsCopiedFromVisibleContext() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "i still get a",
            precedingText: "i still get a",
            visualContextSummary: "So it should render as this Text Okay not thisText Okay"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " 5hould rendera5 this Text Okay not this",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsMixedAlphanumericTechnicalTokens() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "the new",
            precedingText: "the new"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " M1 chip with HTML5 and OAuth2 support",
            for: request
        )

        XCTAssertEqual(normalized, " M1 chip with HTML5 and OAuth2 support")
    }

    func test_normalize_keepsOrdinalAndShortModelTokens() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "we shipped the",
            precedingText: "we shipped the"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " 1st 3D pass for iOS18 and B2B users",
            for: request
        )

        XCTAssertEqual(normalized, " 1st 3D pass for iOS18 and B2B users")
    }

    func test_normalize_dropsLongSuggestionMostlyCopiedFromAuxiliaryContext() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "i still get a",
            precedingText: "i still get a",
            visualContextSummary: "So it should render as this Text Okay not thisText Okay"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " should render as this Text Okay",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsShortConcreteReuseFromAuxiliaryContext() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "Ask Priya about",
            precedingText: "Ask Priya about",
            visualContextSummary: "Aurora launch review\nCustomer timeline"
        )

        let normalized = SuggestionTextNormalizer.normalize(" the timeline", for: request)

        XCTAssertEqual(normalized, " the timeline")
    }

    func test_normalize_dropsQuestionAnswerInsteadOfContinuation() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "do you think we will get it today, experme",
            precedingText: "do you think we will get it today, experme"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " sure, i think we will get it today, exper",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_dropsAnswerLikeSuggestionWhenCurrentSentenceEndsWithQuestionMark() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "When is the delivery?",
            precedingText: "When is the delivery?"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " probably tomorrow",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsAnswerPrefixLikeContinuationWhenEarlierQuestionIsFarFromCaret() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "When is the delivery? Here is the tracking info: the package is",
            precedingText: "When is the delivery? Here is the tracking info: the package is"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " probably in transit",
            for: request
        )

        XCTAssertEqual(normalized, " probably in transit")
    }

    func test_normalize_dropsAssistantMetaResponse() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "still exac",
            precedingText: "still exac"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " I'm sorry, but as an LLM created by",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_dropsInteriorDraftPhraseRepetition() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "do you think we will get it today, experme",
            precedingText: "do you think we will get it today, experme"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " hopefully think we will get it today before lunch",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_dropsShortPhraseCopiedFromEarlierDraft() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "lets see if the test passes. i will try",
            precedingText: "lets see if the test passes. i will try"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " test passes.",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsShortSuggestionWhenDraftNumberWouldOCRNormalizeToWords() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "we have 15 things to do",
            precedingText: "we have 15 things to do"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " is things",
            for: request
        )

        XCTAssertEqual(normalized, " is things")
    }

    func test_normalize_keepsLongSuggestionWhenDraftNumberWouldOCRNormalizeToWords() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "we have 50 reasons now maybe later",
            precedingText: "we have 50 reasons now maybe later"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " so reasons now maybe because",
            for: request
        )

        XCTAssertEqual(normalized, " so reasons now maybe because")
    }

    func test_normalize_dropsNewPhraseAfterLikelyUnfinishedLongToken() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "do you think we will get it today, experme",
            precedingText: "do you think we will get it today, experme"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            " sure, i can check",
            for: request
        )

        XCTAssertEqual(normalized, "")
    }

    func test_normalize_keepsQuestionContinuationWhenItDoesNotAnswer() {
        let request = TabbyTestFixtures.suggestionRequest(
            prefixText: "do you think we will get it today, experme",
            precedingText: "do you think we will get it today, experme"
        )

        let normalized = SuggestionTextNormalizer.normalize(
            "ntal build or tomorrow",
            for: request
        )

        XCTAssertEqual(normalized, "ntal build or tomorrow")
    }
}

final class LocalWordCompletionCandidateReducerTests: XCTestCase {
    func test_currentToken_returnsPartialWordAtCaret() {
        XCTAssertEqual(
            LocalWordCompletionCandidateReducer.currentToken(in: "the last 30 minu"),
            "minu"
        )
    }

    func test_currentToken_ignoresCompletedWordWithTrailingSpace() {
        XCTAssertNil(
            LocalWordCompletionCandidateReducer.currentToken(in: "the last 30 minutes ")
        )
    }

    func test_suggestionTail_returnsOnlyMissingSuffix() {
        let tail = LocalWordCompletionCandidateReducer.suggestionTail(
            currentToken: "minu",
            candidates: ["minimum", "minute", "minutes"]
        )

        XCTAssertEqual(tail, "te")
    }

    func test_suggestionTail_prefersPluralAfterNumber() {
        let tail = LocalWordCompletionCandidateReducer.suggestionTail(
            currentToken: "minu",
            candidates: ["minimum", "minute", "minutes"],
            precedingText: "the last 30 minu"
        )

        XCTAssertEqual(tail, "tes")
    }

    func test_suggestionTail_rejectsCandidateWithoutTokenPrefix() {
        let tail = LocalWordCompletionCandidateReducer.suggestionTail(
            currentToken: "exac",
            candidates: ["answer", "maybe"]
        )

        XCTAssertNil(tail)
    }

    func test_suggestionTail_rejectsSingleCharacterTail() {
        let tail = LocalWordCompletionCandidateReducer.suggestionTail(
            currentToken: "bette",
            candidates: ["better"]
        )

        XCTAssertNil(tail)
    }
}
