import XCTest
@testable import Cotabby

/// Pure-function tests for the prompt character-budget allocator: priority fill, total-budget
/// respect, per-section truncation, min-char drop, and render-order preservation.
final class PromptSectionBudgetTests: XCTestCase {

    private func section(
        _ name: String,
        _ content: String,
        priority: Int,
        min: Int = 0,
        max: Int = 10_000,
        _ trunc: PromptSection.Truncation = .preserveStart
    ) -> PromptSection {
        PromptSection(name: name, content: content, priority: priority, minChars: min, maxChars: max, truncation: trunc)
    }

    func test_allocate_keepsAllWhenBudgetAmple() {
        let kept = PromptSectionBudget.allocate(
            [section("a", "alpha", priority: 10), section("b", "beta", priority: 5)],
            totalChars: 1000
        )
        XCTAssertEqual(kept.map(\.name), ["a", "b"])
    }

    func test_allocate_dropsLowerPriorityWhenBudgetTight() {
        let kept = PromptSectionBudget.allocate(
            [section("low", "xxxxxxxx", priority: 1), section("high", "yyyyyyyy", priority: 9)],
            totalChars: 8
        )
        XCTAssertEqual(kept.map(\.name), ["high"])
    }

    func test_allocate_preservesInputOrderNotPriorityOrder() {
        let kept = PromptSectionBudget.allocate(
            [section("first", "aa", priority: 1), section("second", "bb", priority: 9)],
            totalChars: 1000
        )
        XCTAssertEqual(kept.map(\.name), ["first", "second"])
    }

    func test_allocate_respectsTotalBudget() {
        let kept = PromptSectionBudget.allocate(
            [
                section("a", String(repeating: "a", count: 100), priority: 9),
                section("b", String(repeating: "b", count: 100), priority: 8)
            ],
            totalChars: 120
        )
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.content.count }, 120)
    }

    func test_allocate_dropsSectionThatCannotMeetMinChars() {
        let kept = PromptSectionBudget.allocate(
            [section("big", String(repeating: "x", count: 50), priority: 9, min: 30)],
            totalChars: 20
        )
        XCTAssertTrue(kept.isEmpty)
    }

    func test_allocate_dropsWhitespaceOnlyContent() {
        let kept = PromptSectionBudget.allocate(
            [section("blank", "   ", priority: 9), section("real", "hello", priority: 8)],
            totalChars: 1000
        )
        XCTAssertEqual(kept.map(\.name), ["real"])
    }

    func test_truncate_preserveEndKeepsCaretSide() {
        XCTAssertEqual(PromptSectionBudget.truncate("abcdefgh", toChars: 3, mode: .preserveEnd), "fgh")
    }

    func test_truncate_preserveStartKeepsHead() {
        XCTAssertEqual(PromptSectionBudget.truncate("abcdefgh", toChars: 3, mode: .preserveStart), "abc")
    }

    func test_truncate_returnsInputWhenItFits() {
        XCTAssertEqual(PromptSectionBudget.truncate("abc", toChars: 10, mode: .preserveEnd), "abc")
    }

    // MARK: - Token-aware allocate

    func test_tokenAllocate_keepsAllWhenBudgetAmple() {
        let kept = PromptSectionBudget.allocate(
            [section("a", "alpha", priority: 10), section("b", "beta", priority: 5)],
            totalTokens: 1000,
            estimate: TokenCountEstimator.estimate
        )
        XCTAssertEqual(kept.map(\.name), ["a", "b"])
    }

    func test_tokenAllocate_dropsLowerPriorityWhenBudgetTight() {
        let low = String(repeating: "word ", count: 5)
        let high = String(repeating: "term ", count: 5)
        let kept = PromptSectionBudget.allocate(
            [section("low", low, priority: 1), section("high", high, priority: 9)],
            totalTokens: 5,
            estimate: TokenCountEstimator.estimate
        )
        XCTAssertEqual(kept.map(\.name), ["high"])
    }

    func test_tokenAllocate_respectsTokenBudget() {
        let kept = PromptSectionBudget.allocate(
            [
                section("a", String(repeating: "alpha ", count: 20), priority: 9),
                section("b", String(repeating: "bravo ", count: 20), priority: 8)
            ],
            totalTokens: 25,
            estimate: TokenCountEstimator.estimate
        )
        let used = kept.reduce(0) { $0 + TokenCountEstimator.estimate($1.content) }
        XCTAssertLessThanOrEqual(used, 25)
    }
}
