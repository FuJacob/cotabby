import XCTest
@testable import Cotabby

/// Tests for multi-language support: normalization, the soft prompt hint (which must never *force* a
/// language), one-time legacy migration, and how the hint renders into both prompt backends.
final class LanguageSupportTests: XCTestCase {

    // MARK: - normalize

    func test_normalize_trimsDropsEmptiesAndDedupesCaseInsensitively() {
        XCTAssertEqual(
            LanguageCatalog.normalize(["  German ", "", "  ", "english", "English", "GERMAN"]),
            ["German", "english"]
        )
    }

    func test_normalize_truncatesToMaxLength() {
        let long = String(repeating: "a", count: LanguageCatalog.maxLanguageLength + 10)
        XCTAssertEqual(LanguageCatalog.normalize([long]).first?.count, LanguageCatalog.maxLanguageLength)
    }

    func test_normalize_capsCount() {
        let many = (0..<(LanguageCatalog.maxLanguages + 5)).map { "lang\($0)" }
        XCTAssertEqual(LanguageCatalog.normalize(many).count, LanguageCatalog.maxLanguages)
    }

    // MARK: - promptInstruction

    func test_promptInstruction_emptyReturnsNil() {
        XCTAssertNil(LanguageCatalog.promptInstruction(for: []))
        XCTAssertNil(LanguageCatalog.promptInstruction(for: ["   "]))
    }

    func test_promptInstruction_isSoftHintNotForce() throws {
        let hint = try XCTUnwrap(LanguageCatalog.promptInstruction(for: ["German", "English"]))
        // Both names appear, joined for the statement and the fallback clause.
        XCTAssertTrue(hint.contains("German and English"))
        XCTAssertTrue(hint.contains("German or English"))
        // It must defer to the surrounding text, never force a single language. The old behavior
        // ("Always write the continuation in …") would break a code-switcher's other language.
        XCTAssertTrue(hint.contains("Match the language of the text before the caret"))
        XCTAssertFalse(hint.contains("Always write"))
    }

    func test_promptInstruction_singleLanguageReadsNaturally() {
        let hint = LanguageCatalog.promptInstruction(for: ["German"])
        XCTAssertEqual(hint, "The user usually writes in German. Match the language of the text before "
            + "the caret. If that text is too short or ambiguous to tell, write in German.")
    }

    func test_promptInstruction_threeLanguagesUseOxfordComma() {
        let hint = LanguageCatalog.promptInstruction(for: ["German", "English", "Spanish"])
        XCTAssertTrue(hint?.contains("German, English, and Spanish") == true)
        XCTAssertTrue(hint?.contains("German, English, or Spanish") == true)
    }

    // MARK: - migration

    func test_migration_knownNonEnglishCodeBecomesThatLanguage() {
        XCTAssertEqual(LanguageCatalog.migratedLanguages(fromLegacyCode: "de"), ["German"])
        XCTAssertEqual(LanguageCatalog.migratedLanguages(fromLegacyCode: "zh-Hans"), ["Simplified Chinese"])
    }

    func test_migration_englishAndUnknownCodesBecomeEmpty() {
        // English was the old "no override" default, so it migrates to no declared languages.
        XCTAssertEqual(LanguageCatalog.migratedLanguages(fromLegacyCode: "en"), [])
        XCTAssertEqual(LanguageCatalog.migratedLanguages(fromLegacyCode: "tlh"), [])
    }

    // MARK: - rendering

    func test_llamaRenderer_placesLanguageHintLateRightBeforePrefix() {
        // The length cue is no longer rendered (token-budget-only experiment), and the prompt is now
        // prose with no "Final instruction:" header. This guards that the language hint still lands
        // late — after the app-context sentence and immediately before the prefix, its
        // high-attention slot — so small models actually weigh it.
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Hola",
            applicationName: "Notes",
            completionLengthInstruction: "UNIQUE_LENGTH_CUE",
            userName: nil,
            languageInstruction: LanguageCatalog.promptInstruction(for: ["Spanish"])
        )

        XCTAssertFalse(prompt.contains("UNIQUE_LENGTH_CUE"))

        guard let contextRange = prompt.range(of: "writing in Notes"),
              let langRange = prompt.range(of: "Spanish"),
              let prefixRange = prompt.range(of: "Hola") else {
            XCTFail("Expected app-context sentence, language hint, and prefix in the prompt")
            return
        }
        // Order: app context → language hint → prefix (last).
        XCTAssertLessThan(contextRange.lowerBound, langRange.lowerBound)
        XCTAssertLessThan(langRange.lowerBound, prefixRange.lowerBound)
        XCTAssertTrue(prompt.hasSuffix("Hola"))
    }

    func test_llamaRenderer_emitsNoLanguageLineWhenNoneDeclared() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Hello",
            applicationName: "Notes",
            completionLengthInstruction: "Return only the next few words.",
            userName: nil,
            languageInstruction: LanguageCatalog.promptInstruction(for: [])
        )
        XCTAssertFalse(prompt.contains("usually writes in"))
    }

    func test_foundationModelInstructions_includeLanguageHint() {
        let request = CotabbyTestFixtures.suggestionRequest(
            languageInstruction: LanguageCatalog.promptInstruction(for: ["Japanese"])
        )
        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Japanese"))
    }
}

/// Verifies the one-time upgrade path wired into `SuggestionSettingsModel.init`: a user who picked a
/// language in the old single-select UI must not silently lose it. The pure mapping is covered above;
/// this guards that init reads the legacy key and persists the migrated value under the new key.
/// Key strings are hardcoded on purpose — they mirror the model's private defaults keys, so a rename
/// that would orphan existing users fails here.
@MainActor
final class LanguageMigrationTests: XCTestCase {

    // These run `async` (despite not awaiting) to match the other app-hosted tests: a synchronous
    // @MainActor test blocks the main actor while the host app is still doing its own main-actor
    // startup, which can crash the native runtime. Yielding cooperatively avoids that.
    func test_init_migratesLegacySingleLanguageIntoArray() async {
        let defaults = makeUserDefaults()
        defaults.set("de", forKey: "cotabbyResponseLanguage")

        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        XCTAssertEqual(settings.responseLanguages, ["German"])
        // Persisted under the new key so the migration only runs once.
        XCTAssertEqual(defaults.stringArray(forKey: "cotabbyResponseLanguages"), ["German"])
    }

    func test_init_migratesLegacyEnglishToNoDeclaredLanguages() async {
        let defaults = makeUserDefaults()
        defaults.set("en", forKey: "cotabbyResponseLanguage")

        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        // English was the old "no override" default; it must not become a spurious declared language.
        XCTAssertEqual(settings.responseLanguages, [])
    }

    func test_init_prefersNewMultiLanguageValueOverLegacy() async {
        let defaults = makeUserDefaults()
        defaults.set("de", forKey: "cotabbyResponseLanguage")
        defaults.set(["French", "Italian"], forKey: "cotabbyResponseLanguages")

        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)

        XCTAssertEqual(settings.responseLanguages, ["French", "Italian"])
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "LanguageMigrationTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }

        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
