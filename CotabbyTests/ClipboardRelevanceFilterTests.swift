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
            currentBundleIdentifier: "com.app.notes",
            precedingText: "hello world"
        )
        XCTAssertNil(result)
    }

    // MARK: - Fresh clipboard, same app

    func test_freshClipboard_sameApp_returnsContent() {
        let content = "some copied text"
        let result = filter.filter(
            clipboard: content,
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: "unrelated words here"
        )
        XCTAssertEqual(result, content)
    }

    // MARK: - Fresh clipboard, different app, with overlap

    func test_freshClipboard_differentApp_withOverlap_returnsContent() {
        // First call establishes the source app as Notes.
        _ = filter.filter(
            clipboard: "meeting agenda for Thursday",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: ""
        )

        // Second call from a different app — prefix shares "meeting".
        let result = filter.filter(
            clipboard: "meeting agenda for Thursday",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.mail",
            precedingText: "Let's discuss the meeting"
        )
        XCTAssertEqual(result, "meeting agenda for Thursday")
    }

    // MARK: - Fresh clipboard, different app, no overlap

    func test_freshClipboard_differentApp_noOverlap_returnsNil() {
        _ = filter.filter(
            clipboard: "SELECT * FROM users",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.terminal",
            precedingText: ""
        )

        let result = filter.filter(
            clipboard: "SELECT * FROM users",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: "Dear hiring manager"
        )
        XCTAssertNil(result)
    }

    // MARK: - Staleness

    func test_staleClipboard_returnsNil() {
        _ = filter.filter(
            clipboard: "fresh content",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: "fresh content"
        )

        // Advance time past the staleness threshold.
        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds + 1)

        let result = filter.filter(
            clipboard: "fresh content",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: "fresh content"
        )
        XCTAssertNil(result)
    }

    func test_staleClipboard_differentApp_returnsNil() {
        _ = filter.filter(
            clipboard: "some code",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.xcode",
            precedingText: ""
        )

        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds + 1)

        let result = filter.filter(
            clipboard: "some code",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.slack",
            precedingText: "some code here"
        )
        XCTAssertNil(result)
    }

    // MARK: - Clipboard change resets metadata

    func test_clipboardChange_resetsMetadata() {
        // Initial clipboard from Notes.
        _ = filter.filter(
            clipboard: "old content",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: ""
        )

        // Time passes but clipboard changes from Mail — metadata resets.
        now = now.addingTimeInterval(ClipboardRelevanceFilter.staleThresholdSeconds + 1)

        let result = filter.filter(
            clipboard: "new content from mail",
            pasteboardChangeCount: 2,
            currentBundleIdentifier: "com.app.mail",
            precedingText: "completely different"
        )
        // Same app as source → returned.
        XCTAssertEqual(result, "new content from mail")
    }

    // MARK: - Short tokens ignored

    func test_shortTokensIgnored_inOverlapCheck() {
        _ = filter.filter(
            clipboard: "a b c",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.terminal",
            precedingText: ""
        )

        // Different app, prefix also has only short tokens — no meaningful overlap.
        let result = filter.filter(
            clipboard: "a b c",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: "a b c d e"
        )
        XCTAssertNil(result)
    }

    // MARK: - Case insensitivity

    func test_tokenOverlap_isCaseInsensitive() {
        _ = filter.filter(
            clipboard: "Deployment Pipeline",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.terminal",
            precedingText: ""
        )

        let result = filter.filter(
            clipboard: "Deployment Pipeline",
            pasteboardChangeCount: 1,
            currentBundleIdentifier: "com.app.notes",
            precedingText: "the deployment is running"
        )
        XCTAssertEqual(result, "Deployment Pipeline")
    }
}
