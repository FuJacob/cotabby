import XCTest
@testable import Cotabby

/// Tests for the free-form Extended Context setting and how it renders into both prompt backends.
///
/// Three contracts are locked down here:
/// 1. The settings setter length-caps but does NOT trim whitespace mid-edit (the bug fix that
///    let the user type a space at the end of a word in the editor binding).
/// 2. The factory trims once per request and collapses whitespace-only blobs back to "no value"
///    so an empty editor never produces a heading-only section in the prompt.
/// 3. Each renderer emits the reference-notes block in the right channel — llama's single prompt
///    string, FoundationModel's session instructions — with the same subordination guard the
///    custom-rules block uses.
@MainActor
final class ExtendedContextTests: XCTestCase {

    // MARK: - settings model

    /// Whitespace is NOT trimmed in the setter. If this test starts failing, the editor binding
    /// will stop letting the user type a trailing space inside a word (the original bug report).
    func test_setExtendedContext_preservesTrailingSpaceMidEdit() {
        let defaults = makeIsolatedDefaults()
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        model.setExtendedContext("Hello ")

        XCTAssertEqual(model.extendedContext, "Hello ")
    }

    func test_setExtendedContext_preservesInternalWhitespaceAndNewlines() {
        let defaults = makeIsolatedDefaults()
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        model.setExtendedContext("Glossary:\n- meow: cat sound\n- woof: dog sound\n")

        XCTAssertEqual(model.extendedContext, "Glossary:\n- meow: cat sound\n- woof: dog sound\n")
    }

    func test_setExtendedContext_truncatesAtMaximumCharacters() {
        let defaults = makeIsolatedDefaults()
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        let huge = String(repeating: "a", count: SuggestionSettingsModel.maximumExtendedContextCharacters + 250)

        model.setExtendedContext(huge)

        XCTAssertEqual(model.extendedContext.count, SuggestionSettingsModel.maximumExtendedContextCharacters)
    }

    func test_setExtendedContext_persistsAcrossReload() {
        let defaults = makeIsolatedDefaults()
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        model.setExtendedContext("Glossary: meow = cat sound")
        let reloaded = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        XCTAssertEqual(reloaded.extendedContext, "Glossary: meow = cat sound")
    }

    func test_setExtendedContext_emptyStringClearsPersistedValue() {
        let defaults = makeIsolatedDefaults()
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        model.setExtendedContext("temporary")
        model.setExtendedContext("")

        XCTAssertEqual(model.extendedContext, "")
        let reloaded = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        XCTAssertEqual(reloaded.extendedContext, "")
    }

    // MARK: - request factory

    /// The factory trims (so the prompt doesn't carry stray leading/trailing whitespace) and
    /// collapses whitespace-only content back to nil so renderers can skip the section entirely.
    func test_buildRequest_collapsesWhitespaceOnlyExtendedContextToNil() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
        let settings = CotabbyTestFixtures.settingsSnapshot(extendedContext: "   \n\t  ")

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settings,
            configuration: .standard
        )

        XCTAssertNil(result.request.extendedContext)
    }

    func test_buildRequest_stampsTrimmedExtendedContextOnRequest() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
        let settings = CotabbyTestFixtures.settingsSnapshot(
            extendedContext: "\n  Glossary: meow = cat sound \n"
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settings,
            configuration: .standard
        )

        XCTAssertEqual(result.request.extendedContext, "Glossary: meow = cat sound")
    }

    func test_buildRequest_threadsExtendedContextIntoLlamaPromptPreview() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
        let settings = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .llamaOpenSource,
            extendedContext: "RULE: Every other word should be 'meow'"
        )

        let result = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settings,
            configuration: .standard
        )

        XCTAssertTrue(result.promptPreview.contains("Notes the writer keeps in mind:"))
        XCTAssertTrue(result.promptPreview.contains("RULE: Every other word should be 'meow'"))
    }

    // MARK: - foundation model rendering

    /// Reference notes live in the cached instructions channel so they're not re-tokenized on
    /// every keystroke. If this test starts failing, generation cost will scale with the size of
    /// the user's Extended Context on every request.
    func test_foundationModelInstructions_includeReferenceNotes() {
        let request = CotabbyTestFixtures.suggestionRequest(
            extendedContext: "Glossary: meow = cat sound"
        )
        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Reference notes from the user:"))
        XCTAssertTrue(instructions.contains("Glossary: meow = cat sound"))
        XCTAssertTrue(instructions.contains("never break the rules above"))
    }

    func test_foundationModelPrompt_doesNotIncludeReferenceNotes() {
        // Reference notes belong in the high-priority instructions channel, not the per-request
        // prompt, so the cached session prefix carries them.
        let request = CotabbyTestFixtures.suggestionRequest(
            extendedContext: "Glossary: meow = cat sound"
        )
        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertFalse(prompt.contains("Glossary: meow = cat sound"))
    }

    // MARK: - helpers

    /// Each settings-model test gets its own isolated UserDefaults so state cannot leak between
    /// cases. `removePersistentDomain` resets the in-memory suite to a clean slate before use.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.extendedContext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
