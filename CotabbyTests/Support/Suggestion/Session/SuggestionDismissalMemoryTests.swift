import XCTest
@testable import Cotabby

final class SuggestionDismissalMemoryTests: XCTestCase {
    func testDismissalSurvivesTypingWithinTheWordButExpiresAndStaysFieldScoped() {
        var memory = SuggestionDismissalMemory()
        memory.record(identityKey: 1, precedingText: "Please sche", trailingText: "", completion: "dule a meeting", at: 0)
        func hidden(_ prefix: String, _ text: String, field: UInt64 = 1, time: Double = 1) -> Bool {
            memory.suppresses(identityKey: field, precedingText: prefix, trailingText: "", completion: text, at: time)
        }
        XCTAssertTrue(hidden("Please sche", "dule another meeting"))
        XCTAssertTrue(hidden("Please sched", "ule"))
        XCTAssertFalse(hidden("Please sche", "matic"))
        XCTAssertFalse(hidden("Please sche", "dule", field: 2))
        XCTAssertFalse(hidden("Please sche", "dule", time: 16))
        XCTAssertFalse(hidden("Please schedule ", "another meeting"))
    }
}
