import XCTest
@testable import Cotabby

@MainActor
final class ChromiumInlineAutocompleteTests: XCTestCase {
    private let chrome = "com.google.Chrome"

    func testTheAddressBarsInlineCompletionIsStrippedAndTheCaretStaysAfterTheTypedText() {
        // Typed "weather in", Chrome completed " new york" and selected it.
        let (value, selection) = FocusSnapshotResolver.strippingChromiumInlineAutocomplete(
            value: "weather in new york", selection: NSRange(location: 10, length: 9), role: "AXTextField", bundleIdentifier: chrome
        )
        XCTAssertEqual(value, "weather in")
        XCTAssertEqual(selection, NSRange(location: 10, length: 0))
    }

    func testOtherSelectionsAndHostsPassThrough() {
        let mid = FocusSnapshotResolver.strippingChromiumInlineAutocomplete(
            value: "weather in new york", selection: NSRange(location: 3, length: 4), role: "AXTextField", bundleIdentifier: chrome
        )
        XCTAssertEqual(mid.0, "weather in new york")
        XCTAssertEqual(mid.1, NSRange(location: 3, length: 4))

        let all = FocusSnapshotResolver.strippingChromiumInlineAutocomplete(
            value: "https://example.com", selection: NSRange(location: 0, length: 19), role: "AXTextField", bundleIdentifier: chrome
        )
        XCTAssertEqual(all.1.length, 19, "select-all on focus is the user's whole value, not a completion")

        let safari = FocusSnapshotResolver.strippingChromiumInlineAutocomplete(
            value: "weather in new york", selection: NSRange(location: 10, length: 9), role: "AXTextField", bundleIdentifier: "com.apple.Safari"
        )
        XCTAssertEqual(safari.1.length, 9)

        let textArea = FocusSnapshotResolver.strippingChromiumInlineAutocomplete(
            value: "weather in new york", selection: NSRange(location: 10, length: 9), role: "AXTextArea", bundleIdentifier: chrome
        )
        XCTAssertEqual(textArea.1.length, 9, "only the address bar's text field completes inline")
    }
}
