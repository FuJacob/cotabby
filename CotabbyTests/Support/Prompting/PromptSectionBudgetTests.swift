import XCTest
@testable import Cotabby

/// Pure-function tests for the prompt budget allocator: priority fill with deterministic ties,
/// total-budget respect, per-section caps and truncation direction, min-char drops, whitespace
/// handling, and render-order preservation, for both the character and estimated-token paths.
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

    /// The live caret section: whitespace is meaningful and kept by its end.
    private func caretSection(_ content: String) -> PromptSection {
        PromptSection(
            name: "prefix",
            content: content,
            priority: 100,
            minChars: 1,
            maxChars: 100,
            truncation: .preserveEnd,
            preservesWhitespace: true
        )
    }

    // MARK: - Character allocate

    /// Fill order is by priority, but survivors come back in input order so the renderer, not the
    /// allocator, owns the final layout.
    func test_allocate_ampleBudgetKeepsAllInInputOrder() {
        let kept = PromptSectionBudget.allocate(
            [section("first", "aa", priority: 1), section("second", "bb", priority: 9)],
            totalChars: 1000
        )
        XCTAssertEqual(kept.map(\.name), ["first", "second"])
    }

    func test_allocate_dropsLowerPriorityWhenBudgetTight() {
        let kept = PromptSectionBudget.allocate(
            [section("low", "xxxxxxxx", priority: 1), section("high", "yyyyyyyy", priority: 9)],
            totalChars: 8
        )
        XCTAssertEqual(kept.map(\.name), ["high"])
    }

    /// Equal priorities fill in input order, so the same inputs always produce the same prompt.
    func test_allocate_equalPriorityTieGoesToEarlierSection() {
        let kept = PromptSectionBudget.allocate(
            [section("a", "xxxx", priority: 5), section("b", "yyyy", priority: 5)],
            totalChars: 4
        )
        XCTAssertEqual(kept.map(\.name), ["a"])
    }

    /// With `minChars` 0, a lower-priority section takes exactly the leftover budget.
    func test_allocate_truncatesLowerPriorityToTheRemainder() {
        let kept = PromptSectionBudget.allocate(
            [
                section("a", String(repeating: "a", count: 100), priority: 9),
                section("b", String(repeating: "b", count: 100), priority: 8)
            ],
            totalChars: 120
        )
        XCTAssertEqual(kept.map(\.content), [String(repeating: "a", count: 100), String(repeating: "b", count: 20)])
    }

    /// `maxChars` bounds a section even when the total budget is ample; the truncation mode picks
    /// which end survives.
    func test_allocate_maxCharsCapsSectionInItsTruncationDirection() {
        let kept = PromptSectionBudget.allocate(
            [
                section("head", "abcdef", priority: 5, max: 3, .preserveStart),
                section("tail", "abcdef", priority: 5, max: 3, .preserveEnd)
            ],
            totalChars: 1000
        )
        XCTAssertEqual(kept.map(\.content), ["abc", "def"])
    }

    /// A section is kept when the cap exactly meets `minChars` and dropped one character below it.
    func test_allocate_minCharsBoundary() {
        let candidate = section("s", "xxxxx", priority: 5, min: 5)
        XCTAssertEqual(PromptSectionBudget.allocate([candidate], totalChars: 5).map(\.name), ["s"])
        XCTAssertEqual(PromptSectionBudget.allocate([candidate], totalChars: 4), [])
    }

    /// A high-priority section dropped for missing its minimum consumes no budget, so a smaller
    /// lower-priority section can still use it.
    func test_allocate_droppedMinCharsSectionLeavesBudgetForOthers() {
        let kept = PromptSectionBudget.allocate(
            [
                section("big", String(repeating: "x", count: 50), priority: 9, min: 30),
                section("small", "ok", priority: 1)
            ],
            totalChars: 20
        )
        XCTAssertEqual(kept.map(\.name), ["small"])
    }

    func test_allocate_nonPositiveBudgetKeepsNothing() {
        for budget in [0, -5] {
            XCTAssertEqual(
                PromptSectionBudget.allocate([section("a", "alpha", priority: 9)], totalChars: budget),
                [],
                "budget \(budget)"
            )
        }
    }

    func test_allocate_dropsWhitespaceOnlyContent() {
        let kept = PromptSectionBudget.allocate(
            [section("blank", "   ", priority: 9), section("real", "hello", priority: 8)],
            totalChars: 1000
        )
        XCTAssertEqual(kept.map(\.name), ["real"])
    }

    /// Reference sections are trimmed after truncation and charged only for what they keep, so
    /// trimmed edge whitespace is returned to later sections.
    func test_allocate_chargesOnlyTrimmedContentForReferenceSections() {
        let kept = PromptSectionBudget.allocate(
            [section("a", " x ", priority: 9), section("b", "yyy", priority: 5)],
            totalChars: 4
        )
        XCTAssertEqual(kept.map(\.content), ["x", "yyy"])
    }

    func test_allocate_countsPreservedCaretWhitespaceAgainstTheBudget() {
        let prefix = caretSection("Hello \n  ")
        let kept = PromptSectionBudget.allocate(
            [prefix, section("notes", "extra", priority: 10)],
            totalChars: prefix.content.count
        )
        XCTAssertEqual(kept, [prefix])
    }

    func test_allocate_preservesCaretSideWhitespaceWhenTruncating() {
        let kept = PromptSectionBudget.allocate([caretSection("Hello \n  ")], totalChars: 3)
        XCTAssertEqual(kept.map(\.content), ["\n  "])
    }

    // MARK: - truncate

    func test_truncate_keepsRequestedEndOrReturnsInputUnchanged() {
        let cases: [(text: String, chars: Int, mode: PromptSection.Truncation, expected: String)] = [
            ("abcdefgh", 3, .preserveEnd, "fgh"),
            ("abcdefgh", 3, .preserveStart, "abc"),
            ("abc", 10, .preserveEnd, "abc"),
            ("abc", 3, .preserveStart, "abc"),
            ("abc", 0, .preserveStart, ""),
            ("abc", -1, .preserveEnd, "")
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptSectionBudget.truncate(testCase.text, toChars: testCase.chars, mode: testCase.mode),
                testCase.expected,
                "\(testCase.text) to \(testCase.chars) \(testCase.mode)"
            )
        }
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

    /// With a one-character-per-token estimator the token cap maps directly to characters, so the
    /// remainder truncation and the `maxChars` cap are both exactly observable.
    func test_tokenAllocate_truncatesToRemainingTokensAndMaxChars() {
        let kept = PromptSectionBudget.allocate(
            [
                section("a", "aaaa", priority: 9),
                section("b", "bbbbbb", priority: 5),
                section("capped", "cccccc", priority: 7, max: 2)
            ],
            totalTokens: 9,
            estimate: { $0.count }
        )
        // Fill order a (4, leaves 5), capped (2 by maxChars, leaves 3), b (3 of 6).
        XCTAssertEqual(kept.map(\.content), ["aaaa", "bbb", "cc"])
    }

    func test_tokenAllocate_dropsWhitespaceOnlyContent() {
        let kept = PromptSectionBudget.allocate(
            [section("blank", "   ", priority: 9), section("real", "hello", priority: 8)],
            totalTokens: 100,
            estimate: TokenCountEstimator.estimate
        )
        XCTAssertEqual(kept.map(\.name), ["real"])
    }

    func test_tokenAllocate_preservesWhitespaceAndChargesItsEstimate() {
        let prefix = caretSection("word  \n\t")
        // One character per token makes this accounting test independent of the production
        // heuristic. Whitespace must be included in the content handed to any estimator.
        let kept = PromptSectionBudget.allocate(
            [prefix, section("notes", "extra", priority: 10)],
            totalTokens: prefix.content.count,
            estimate: { $0.count }
        )
        XCTAssertEqual(kept, [prefix])
    }
}
