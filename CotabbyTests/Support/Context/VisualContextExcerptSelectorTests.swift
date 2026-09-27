import XCTest
@testable import Cotabby

final class VisualContextExcerptSelectorTests: XCTestCase {
    func test_preservesNamesDeadlinesAndAmountsAfterConfidenceFiltering() {
        let text = "Casey asks for 12 copies by September 25 for 450 dollars"
        XCTAssertEqual(select([.init(text: text, confidence: 0.95)], budget: 4000), text)
    }

    func test_keepsNearbyConversationBeforeDistantSidebarAndRestoresReadingOrder() {
        let lines = [
            line("The earlier message explains the project", x: 0.4, y: 0.5),
            line("The newest message asks about the deadline", x: 0.4, y: 0.3),
            line("The unrelated sidebar lists another project", x: 0, y: 0.25)
        ]
        let result = select(lines, budget: 90)
        XCTAssertEqual(result, lines.prefix(2).map(\.text).joined(separator: "\n"))
    }

    func test_dropsFieldEchoesDuplicatesAndLowConfidence() {
        let lines = [
            line("My current draft", x: 0.4, y: 0.2),
            line("Please send the project agenda", x: 0.4, y: 0.3),
            line("Please send the project agenda", x: 0.4, y: 0.4),
            OCRTextHygiene.OCRLine(text: "unreliable recognition", confidence: 0.1)
        ]
        let result = VisualContextExcerptSelector.select(
            lines: lines, fieldText: "My current draft", focusBounds: nil, maxCharacters: 4000
        )
        XCTAssertEqual(result, "Please send the project agenda")
    }

    func test_withoutGeometryPrefersRecentLinesAndHonorsBudget() {
        let lines = ["Old conversation", "New conversation"]
            .map { OCRTextHygiene.OCRLine(text: $0, confidence: 1) }
        XCTAssertEqual(VisualContextExcerptSelector.select(
            lines: lines, fieldText: "", focusBounds: nil, maxCharacters: 16
        ), "New conversation")
        XCTAssertEqual(select(lines, budget: 0), "")
    }

    func test_retainsMoreThanOldFortyLineLimitWhenBudgetAllows() {
        let lines = (0..<80).map { OCRTextHygiene.OCRLine(text: "Project agenda item \($0)", confidence: 1) }
        let result = select(lines, budget: 4000)
        XCTAssertEqual(result.components(separatedBy: "\n").count, 80)
        XCTAssertLessThanOrEqual(result.count, 4000)
    }

    private func line(_ text: String, x: Double, y: Double) -> OCRTextHygiene.OCRLine {
        .init(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: 0.25, height: 0.03))
    }

    private func select(_ lines: [OCRTextHygiene.OCRLine], budget: Int) -> String {
        VisualContextExcerptSelector.select(
            lines: lines, fieldText: "", focusBounds: CGRect(x: 0.4, y: 0.1, width: 0.4, height: 0.1),
            maxCharacters: budget
        )
    }
}
