import XCTest
@testable import Cotabby

@MainActor
final class ClipboardRelevanceFilterTests: XCTestCase {

    private var now: Date!
    private var filter: ClipboardRelevanceFilter!

    override func setUp() {
        super.setUp()
        now = Date()
        filter = ClipboardRelevanceFilter(dateProvider: { [unowned self] in self.now })
    }

    // MARK: - Nil input

    func test_nilClipboard_returnsNil() {
        let result = filter.filter(
            clipboard: nil,
            pasteboardChangeCount: 1,
            precedingText: "hello world"
        )
        XCTAssertNil(result)
    }

    // MARK: - Baseline gating

    /// `NSPasteboard.changeCount` is a non-zero cumulative counter on a real system, so the
    /// first observation can't tell us how old the clipboard content actually is. The filter
    /// records the baseline silently and refuses injection until a *new* copy is detected.
    func test_firstObservation_returnsNilEvenWithOverlap() {
        let result = filter.filter(
            clipboard: "meeting agenda",
            pasteboardChangeCount: 42,
            precedingText: "the meeting starts soon"
        )
        XCTAssertNil(result)
    }

    func test_firstChangeAfterBaseline_returnsContentWhenOverlapMatches() {
        // Baseline observation — counts as "we know nothing about how old this is".
        _ = filter.filter(
            clipboard: "irrelevant baseline content",
            pasteboardChangeCount: 42,
            precedingText: ""
        )

        // User performs a fresh copy while Cotabby is running.
        let result = filter.filter(
            clipboard: "meeting agenda for Thursday",
            pasteboardChangeCount: 43,
            precedingText: "Let's discuss the meeting"
        )
        XCTAssertEqual(result, "meeting agenda for Thursday")
    }

    // MARK: - Token overlap

    func test_freshClipboard_noOverlap_returnsNil() {
        _ = filter.filter(
            clipboard: "irrelevant baseline content",
            pasteboardChangeCount: 1,
            precedingText: ""
        )

        let result = filter.filter(
            clipboard: "SELECT * FROM users",
            pasteboardChangeCount: 2,
            precedingText: "Dear hiring manager"
        )
        XCTAssertNil(result)
    }

    func test_shortTokensIgnored_inOverlapCheck() {
        _ = filter.filter(
            clipboard: "irrelevant baseline content",
            pasteboardChangeCount: 1,
            precedingText: ""
        )

        // Prefix and clipboard share only sub-3-char tokens, which the tokenizer ignores.
        let result = filter.filter(
            clipboard: "a b c",
            pasteboardChangeCount: 2,
            precedingText: "a b c d e"
        )
        XCTAssertNil(result)
    }

    func test_tokenOverlap_isCaseInsensitive() {
        _ = filter.filter(
            clipboard: "irrelevant baseline content",
            pasteboardChangeCount: 1,
            precedingText: ""
        )

        let result = filter.filter(
            clipboard: "Deployment Pipeline",
            pasteboardChangeCount: 2,
            precedingText: "the deployment is running"
        )
        XCTAssertEqual(result, "Deployment Pipeline")
    }

    // MARK: - Staleness

    func test_staleClipboard_returnsNil() {
        // Establish baseline.
        _ = filter.filter(
            clipboard: "old baseline",
            pasteboardChangeCount: 1,
            precedingText: ""
        )

        // A fresh copy happens — staleness clock starts here.
        _ = filter.filter(
            clipboard: "fresh content here",
            pasteboardChangeCount: 2,
            precedingText: "fresh content here"
        )

        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds + 1)

        let result = filter.filter(
            clipboard: "fresh content here",
            pasteboardChangeCount: 2,
            precedingText: "fresh content here"
        )
        XCTAssertNil(result)
    }

    func test_newCopyResetsStalenessClock() {
        _ = filter.filter(
            clipboard: "baseline",
            pasteboardChangeCount: 1,
            precedingText: ""
        )

        // First real copy.
        _ = filter.filter(
            clipboard: "first content",
            pasteboardChangeCount: 2,
            precedingText: "first content"
        )

        // Time passes past the staleness threshold.
        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds + 1)

        // A new copy resets the clock.
        let result = filter.filter(
            clipboard: "second content matching prefix",
            pasteboardChangeCount: 3,
            precedingText: "second content"
        )
        XCTAssertEqual(result, "second content matching prefix")
    }
}
