import XCTest
@testable import Cotabby

/// Tests `ComposeRequestFactory` — the pure builder that turns a focused-input context plus settings
/// into a `ComposeRequest` with sane clipping and sampling defaults.
///
/// Compose Mode uses larger token budgets and looser sampling than autocomplete; these tests lock
/// in those minimums so future tuning cannot accidentally make Compose behave like autocomplete.
final class ComposeRequestFactoryTests: XCTestCase {
    func test_buildRequest_clipsLongTypedPrefixWithEllipsis() {
        let oversizedPrefix = String(repeating: "a", count: 5_000)
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: oversizedPrefix)

        let result = ComposeRequestFactory.buildRequest(
            context: context,
            settings: settings(),
            configuration: .standard,
            surroundingContext: "",
            clipboardContext: nil
        )

        XCTAssertLessThanOrEqual(result.request.typedPrefix.count, 4_000)
        XCTAssertTrue(result.request.typedPrefix.hasSuffix("..."))
    }

    func test_buildRequest_clipsTrailingTextAndSurroundingContext() {
        let trailing = String(repeating: "b", count: 2_000)
        let surrounding = String(repeating: "c", count: 12_000)
        let context = CotabbyTestFixtures.focusedInputContext(
            precedingText: "Hi",
            trailingText: trailing
        )

        let result = ComposeRequestFactory.buildRequest(
            context: context,
            settings: settings(),
            configuration: .standard,
            surroundingContext: surrounding,
            clipboardContext: nil
        )

        XCTAssertLessThanOrEqual(result.request.trailingText.count, 1_000)
        XCTAssertLessThanOrEqual(result.request.surroundingContext.count, 8_000)
    }

    func test_buildRequest_omitsClipboardWhenDisabledEvenIfProvided() {
        let result = ComposeRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(),
            settings: settings(isClipboardContextEnabled: false),
            configuration: .standard,
            surroundingContext: "Context.",
            clipboardContext: "Should be ignored."
        )

        XCTAssertNil(result.request.clipboardContext)
    }

    func test_buildRequest_includesClipboardWhenEnabled() {
        let result = ComposeRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(),
            settings: settings(isClipboardContextEnabled: true),
            configuration: .standard,
            surroundingContext: "Context.",
            clipboardContext: "https://example.com"
        )

        XCTAssertEqual(result.request.clipboardContext, "https://example.com")
    }

    func test_buildRequest_appliesComposeSamplingMinimumsAboveAutocomplete() {
        // Autocomplete uses temperature 0.1 and 8 tokens. Compose should bump both up because a
        // multi-sentence draft needs more headroom than an inline tail.
        let result = ComposeRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(),
            settings: settings(),
            configuration: .standard,
            surroundingContext: "",
            clipboardContext: nil
        )

        XCTAssertGreaterThanOrEqual(result.request.maxPredictionTokens, 256)
        XCTAssertGreaterThanOrEqual(result.request.temperature, 0.35)
        XCTAssertGreaterThanOrEqual(result.request.topK, 40)
        XCTAssertGreaterThanOrEqual(result.request.topP, 0.9)
        XCTAssertGreaterThanOrEqual(result.request.repetitionPenalty, 1.08)
    }

    func test_buildRequest_carriesUserNameAndUserTagsThroughToTheRequest() {
        let snapshot = SuggestionSettingsSnapshot(
            isGloballyEnabled: true,
            disabledAppBundleIdentifiers: [],
            selectedInteractionMode: .compose,
            selectedEngine: .llamaOpenSource,
            selectedWordCountPreset: .sevenToTwelve,
            isClipboardContextEnabled: true,
            userName: "Jacob",
            userTags: ["engineer", "macOS"],
            debounceMilliseconds: 50,
            focusPollIntervalMilliseconds: 50,
            isMultiLineEnabled: false
        )

        let result = ComposeRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(),
            settings: snapshot,
            configuration: .standard,
            surroundingContext: "Context",
            clipboardContext: nil
        )

        XCTAssertEqual(result.request.userName, "Jacob")
        XCTAssertEqual(result.request.userTags, ["engineer", "macOS"])
    }

    func test_buildRequest_includesPromptPreviewMatchingRenderer() {
        let result = ComposeRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(applicationName: "GitHub"),
            settings: settings(),
            configuration: .standard,
            surroundingContext: "Surrounding context.",
            clipboardContext: nil
        )

        XCTAssertEqual(result.promptPreview, ComposePromptRenderer.prompt(for: result.request))
    }

    private func settings(
        isClipboardContextEnabled: Bool = true,
        userName: String = "",
        userTags: [String] = []
    ) -> SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: true,
            disabledAppBundleIdentifiers: [],
            selectedInteractionMode: .compose,
            selectedEngine: .llamaOpenSource,
            selectedWordCountPreset: .sevenToTwelve,
            isClipboardContextEnabled: isClipboardContextEnabled,
            userName: userName,
            userTags: userTags,
            debounceMilliseconds: 50,
            focusPollIntervalMilliseconds: 50,
            isMultiLineEnabled: false
        )
    }
}
