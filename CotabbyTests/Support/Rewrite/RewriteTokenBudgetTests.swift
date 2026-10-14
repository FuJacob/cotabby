import XCTest
@testable import Cotabby

/// The rewrite token budget (every provider that takes one: Apple Intelligence, llama, an endpoint's
/// or MLX's completions route) fits what the cleaner accepts, so Longer is not cut off mid-sentence
/// and previewed as if it were finished.
final class RewriteTokenBudgetTests: XCTestCase {
    func test_longerGetsRoomForAFullerMessage() {
        let draft = String(repeating: "a", count: 120)
        let longer = RewritePromptBuilder.tokenBudget(RewriteRequest(selection: draft, action: .longer))
        let formal = RewritePromptBuilder.tokenBudget(RewriteRequest(selection: draft, action: .formal))
        // The cleaner lets Longer reach 120 * 8 + 400 = 1,360 characters, about 340 tokens.
        XCTAssertGreaterThanOrEqual(longer, (120 * 8 + 400) / 4)
        XCTAssertEqual(formal, 120 * 3 / 8 + 48)
    }

    func test_budgetIsCapped() {
        let draft = String(repeating: "a", count: 2_000)
        XCTAssertEqual(RewritePromptBuilder.tokenBudget(RewriteRequest(selection: draft, action: .longer)), 800)
        XCTAssertEqual(RewritePromptBuilder.tokenBudget(RewriteRequest(selection: draft, action: .rewrite)), 798)
    }
}
