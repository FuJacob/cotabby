import XCTest
@testable import Cotabby

/// Escape memory: a dismissed first word stays suppressed while the user types through it in the
/// same field, but the memory is field-scoped, trailing-text-scoped, time-bounded, and capped.
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
        XCTAssertFalse(hidden("Please sche", "dule", time: 15), "the 15s lifetime is exclusive at its end")
        XCTAssertFalse(hidden("Please schedule ", "another meeting"))
    }

    func testOnlyTheFirstWordOfALeadingSpaceCompletionIsRemembered() {
        var memory = SuggestionDismissalMemory()
        memory.record(identityKey: 1, precedingText: "Please schedule", trailingText: "",
                      completion: " another meeting", at: 0)
        func hidden(_ prefix: String, _ text: String) -> Bool {
            memory.suppresses(identityKey: 1, precedingText: prefix, trailingText: "", completion: text, at: 1)
        }
        XCTAssertTrue(hidden("Please schedule", " another day"), "same first word, different tail")
        XCTAssertTrue(hidden("Please schedule an", "other"), "typing into the dismissed word")
        XCTAssertTrue(hidden("Please schedule", " an"), "a proposal that is a prefix of the dismissed word")
        XCTAssertFalse(hidden("Please schedule", " anyway"), "a different first word is a fresh offer")
    }

    func testTrailingTextChangeAndEmptyCompletionsDoNotSuppress() {
        var memory = SuggestionDismissalMemory()
        memory.record(identityKey: 1, precedingText: "Hi ", trailingText: "", completion: "", at: 0)
        XCTAssertFalse(memory.suppresses(identityKey: 1, precedingText: "Hi ", trailingText: "",
                                         completion: "", at: 1), "an empty completion is never recorded")

        memory.record(identityKey: 1, precedingText: "Hi ", trailingText: " end", completion: "there", at: 0)
        XCTAssertTrue(memory.suppresses(identityKey: 1, precedingText: "Hi ", trailingText: " end",
                                        completion: "there", at: 1))
        XCTAssertFalse(memory.suppresses(identityKey: 1, precedingText: "Hi ", trailingText: " edited",
                                         completion: "there", at: 1))
    }

    func testMemoryKeepsOnlyTheEightMostRecentDismissals() {
        var memory = SuggestionDismissalMemory()
        for key in UInt64(1)...9 {
            memory.record(identityKey: key, precedingText: "Please sche", trailingText: "",
                          completion: "dule", at: 0)
        }
        XCTAssertFalse(memory.suppresses(identityKey: 1, precedingText: "Please sche", trailingText: "",
                                         completion: "dule", at: 1), "the oldest entry is evicted")
        for key in UInt64(2)...9 {
            XCTAssertTrue(memory.suppresses(identityKey: key, precedingText: "Please sche", trailingText: "",
                                            completion: "dule", at: 1), "entry \(key)")
        }
    }

    func testLongFieldsAnchorOnTheBoundedPrefixSuffix() {
        // Only the last 256 characters are stored, so a dismissal in a long document is still found
        // by locating that suffix in the live prefix.
        let longPrefix = String(repeating: "lorem ipsum ", count: 40) + "Please sche"
        var memory = SuggestionDismissalMemory()
        memory.record(identityKey: 1, precedingText: longPrefix, trailingText: "", completion: "dule it", at: 0)
        XCTAssertTrue(memory.suppresses(identityKey: 1, precedingText: longPrefix, trailingText: "",
                                        completion: "dule", at: 1))
        XCTAssertTrue(memory.suppresses(identityKey: 1, precedingText: longPrefix + "du", trailingText: "",
                                        completion: "le", at: 1))
    }
}
