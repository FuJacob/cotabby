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
}
