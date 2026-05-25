import XCTest
@testable import Cotabby

/// Tests for custom-rule normalization and how rules render into both prompt backends.
///
/// Pure-function tests: normalization is deterministic, and the renderers must place user rules
/// after the base rules with an explicit subordination line so a "rule" can never override the
/// autocomplete/output contract.
final class CustomRulesTests: XCTestCase {

    // MARK: - normalize

    func test_normalize_trimsAndDropsEmpties() {
        XCTAssertEqual(
            CustomRulesCatalog.normalize(["  Write concisely  ", "", "   ", "Be formal"]),
            ["Write concisely", "Be formal"]
        )
    }

    func test_normalize_dedupesCaseInsensitivelyKeepingFirst() {
        XCTAssertEqual(
            CustomRulesCatalog.normalize(["Casual tone", "casual tone", "CASUAL TONE"]),
            ["Casual tone"]
        )
    }

    func test_normalize_truncatesToMaxLength() {
        let long = String(repeating: "a", count: CustomRulesCatalog.maxRuleLength + 25)
        let normalized = CustomRulesCatalog.normalize([long])
        XCTAssertEqual(normalized.first?.count, CustomRulesCatalog.maxRuleLength)
    }

    func test_normalize_capsCount() {
        let many = (0..<(CustomRulesCatalog.maxRules + 8)).map { "rule \($0)" }
        XCTAssertEqual(CustomRulesCatalog.normalize(many).count, CustomRulesCatalog.maxRules)
    }

    // MARK: - llama rendering

    func test_llamaRenderer_emitsRulesAfterBaseRulesWithSubordination() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Hello",
            applicationName: "Notes",
            completionLengthInstruction: "Return only the next few words.",
            userName: nil,
            customRules: ["Use British spelling", "Never use em dashes"]
        )

        XCTAssertTrue(prompt.contains("Your style preferences:"))
        XCTAssertTrue(prompt.contains("- Use British spelling"))
        XCTAssertTrue(prompt.contains("- Never use em dashes"))
        XCTAssertTrue(prompt.contains("never break the rules above"))

        // The base task rules must precede the user style section.
        let baseIndex = try? XCTUnwrap(prompt.range(of: "Task:"))
        let rulesIndex = try? XCTUnwrap(prompt.range(of: "Your style preferences:"))
        if let baseIndex, let rulesIndex {
            XCTAssertLessThan(baseIndex.lowerBound, rulesIndex.lowerBound)
        }
    }

    func test_llamaRenderer_emitsNoRuleSectionWhenEmpty() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Hello",
            applicationName: "Notes",
            completionLengthInstruction: "Return only the next few words.",
            userName: nil,
            customRules: []
        )

        XCTAssertFalse(prompt.contains("Your style preferences:"))
    }

    // MARK: - foundation model rendering

    func test_foundationModelInstructions_includeRules() {
        let request = CotabbyTestFixtures.suggestionRequest(customRules: ["Keep a casual tone"])
        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Your style preferences:"))
        XCTAssertTrue(instructions.contains("- Keep a casual tone"))
        XCTAssertTrue(instructions.contains("never break the rules above"))
    }

    func test_foundationModelPrompt_doesNotIncludeRules() {
        // Rules belong in the high-priority instructions channel, not the per-request prompt.
        let request = CotabbyTestFixtures.suggestionRequest(customRules: ["Keep a casual tone"])
        let prompt = FoundationModelPromptRenderer.prompt(for: request)

        XCTAssertFalse(prompt.contains("Keep a casual tone"))
    }

    // MARK: - language

    func test_language_englishEmitsNoInstruction() {
        XCTAssertNil(SuggestionLanguage.english.promptInstruction)
    }

    func test_language_nonEnglishEmitsForcingInstruction() {
        let instruction = SuggestionLanguage.spanish.promptInstruction
        XCTAssertNotNil(instruction)
        XCTAssertTrue(instruction?.contains("Spanish") == true)
    }

    func test_llamaRenderer_includesLanguageInstructionBeforeLengthCue() {
        let prompt = LlamaPromptRenderer.prompt(
            prefixText: "Hola",
            applicationName: "Notes",
            completionLengthInstruction: "UNIQUE_LENGTH_CUE",
            userName: nil,
            languageInstruction: SuggestionLanguage.spanish.promptInstruction
        )

        guard let langRange = prompt.range(of: "Spanish"),
              let lenRange = prompt.range(of: "UNIQUE_LENGTH_CUE") else {
            XCTFail("Expected language directive and length cue in the prompt")
            return
        }
        XCTAssertLessThan(langRange.lowerBound, lenRange.lowerBound)
    }

    func test_foundationModelInstructions_includeLanguageOverride() {
        let request = CotabbyTestFixtures.suggestionRequest(
            languageInstruction: SuggestionLanguage.japanese.promptInstruction
        )
        let instructions = FoundationModelPromptRenderer.sessionInstructions(for: request)

        XCTAssertTrue(instructions.contains("Japanese"))
    }
}
