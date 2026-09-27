import XCTest
@testable import Cotabby

/// Tests for clipboard relevance gating: the first observation only records a change-count
/// baseline, injection requires a copy observed while Cotabby runs, content expires after the
/// staleness window, and it must share a 3+ character token with the caret prefix.
@MainActor
final class ClipboardRelevanceFilterTests: XCTestCase {

    private var now: Date!
    private var filter: ClipboardRelevanceFilter!

    override func setUp() {
        super.setUp()
        // A whole-second reference date keeps the threshold arithmetic below exact in floating point.
        now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        filter = ClipboardRelevanceFilter(dateProvider: { [unowned self] in self.now })
    }

    /// Records the change-count baseline; the returned value is always nil and not interesting.
    private func establishBaseline(changeCount: Int = 1) {
        XCTAssertNil(filter.filter(clipboard: "baseline", pasteboardChangeCount: changeCount, precedingText: ""))
    }

    // MARK: - Nil input and baseline gating

    func test_nilClipboard_returnsNil() {
        establishBaseline()
        XCTAssertNil(filter.filter(clipboard: nil, pasteboardChangeCount: 2, precedingText: "hello world"))
    }

    /// `NSPasteboard.changeCount` is a non-zero cumulative counter on a real system, so the
    /// first observation can't tell us how old the clipboard content actually is. The filter
    /// records the baseline silently and refuses injection until a *new* copy is detected.
    func test_firstObservation_returnsNilEvenWithOverlap() {
        XCTAssertNil(filter.filter(
            clipboard: "meeting agenda",
            pasteboardChangeCount: 42,
            precedingText: "the meeting starts soon"
        ))
    }

    /// A nil (non-text) clipboard returns before the baseline is recorded, so the first text
    /// observation after it is still treated as the baseline rather than as a fresh copy.
    func test_nilClipboardDoesNotRecordTheBaseline() {
        XCTAssertNil(filter.filter(clipboard: nil, pasteboardChangeCount: 1, precedingText: ""))
        XCTAssertNil(filter.filter(
            clipboard: "meeting agenda",
            pasteboardChangeCount: 2,
            precedingText: "the meeting starts soon"
        ))
    }

    /// Without a change after the baseline there is no known copy time, so even overlapping
    /// content stays out of the prompt.
    func test_unchangedCountAfterBaseline_returnsNil() {
        establishBaseline(changeCount: 42)
        XCTAssertNil(filter.filter(
            clipboard: "meeting agenda",
            pasteboardChangeCount: 42,
            precedingText: "the meeting starts soon"
        ))
    }

    func test_firstChangeAfterBaseline_returnsContentWhenOverlapMatches() {
        establishBaseline(changeCount: 42)
        XCTAssertEqual(
            filter.filter(
                clipboard: "meeting agenda for Thursday",
                pasteboardChangeCount: 43,
                precedingText: "Let's discuss the meeting"
            ),
            "meeting agenda for Thursday"
        )
    }

    // MARK: - Token overlap

    /// Overlap is case-insensitive and ignores tokens shorter than three characters.
    func test_tokenOverlapRules() {
        let cases: [(clipboard: String, prefix: String, expected: String?)] = [
            ("Deployment Pipeline", "the deployment is running", "Deployment Pipeline"),
            ("SELECT * FROM users", "Dear hiring manager", nil),
            ("a b c", "a b c d e", nil)
        ]
        // One filter for every case: each new change count is a fresh copy that restarts the clock,
        // so the overlap rule is all that differs. Reassigning `filter` here instead would free a
        // `@MainActor` object inside the test body, which crashes the CI host (macOS 15 runtime).
        establishBaseline()
        for (offset, testCase) in cases.enumerated() {
            XCTAssertEqual(
                filter.filter(
                    clipboard: testCase.clipboard,
                    pasteboardChangeCount: offset + 2,
                    precedingText: testCase.prefix
                ),
                testCase.expected,
                "case \(offset): \(testCase.clipboard)"
            )
        }
    }

    // MARK: - Staleness

    /// Repeated reads of the same copy stay eligible just under the threshold and expire exactly
    /// at it (the comparison is strict), because only a change-count bump restarts the clock.
    func test_staleness_expiresAtThresholdFromTheCopy() {
        establishBaseline()
        XCTAssertEqual(
            filter.filter(clipboard: "fresh content", pasteboardChangeCount: 2, precedingText: "fresh content"),
            "fresh content"
        )

        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds - 1)
        XCTAssertEqual(
            filter.filter(clipboard: "fresh content", pasteboardChangeCount: 2, precedingText: "fresh content"),
            "fresh content"
        )

        now = now.addingTimeInterval(1)
        XCTAssertNil(filter.filter(clipboard: "fresh content", pasteboardChangeCount: 2, precedingText: "fresh content"))
    }

    func test_newCopyResetsStalenessClock() {
        establishBaseline()
        _ = filter.filter(clipboard: "first content", pasteboardChangeCount: 2, precedingText: "first content")

        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds + 1)

        XCTAssertEqual(
            filter.filter(
                clipboard: "second content matching prefix",
                pasteboardChangeCount: 3,
                precedingText: "second content"
            ),
            "second content matching prefix"
        )
    }
}
