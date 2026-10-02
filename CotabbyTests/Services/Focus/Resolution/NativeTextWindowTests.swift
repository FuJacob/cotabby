import XCTest
@testable import Cotabby

/// Tests the caret-windowed text assembly behind `FocusSnapshotResolver.nativeTextWindow`, with the
/// host's `AXStringForRange` replaced by a closure over a plain string.
///
/// The regression guarded here is an empty Catalyst field (WhatsApp's composer): it answers every
/// string read with `kAXErrorNoValue`, so asking it for the empty range before the caret failed the
/// window and left the field unsupported, with no ghost and no field icon until the first keystroke.
@MainActor
final class NativeTextWindowTests: XCTestCase {
    /// A host that reads `text`, or a Catalyst-style host that has no value at all when `text` is nil.
    private func reader(_ text: String?, log: @escaping (NSRange) -> Void = { _ in }) -> (NSRange) -> String? {
        { range in
            log(range)
            guard let text else { return nil }
            return (text as NSString).substring(with: range)
        }
    }

    func testEmptyFieldWhoseHostHasNoValueIsAnEmptyWindowWithoutAskingTheHost() throws {
        var reads: [NSRange] = []
        let window = try XCTUnwrap(FocusSnapshotResolver.windowedTextSelection(
            selection: NSRange(location: 0, length: 0),
            documentLength: 0,
            contextWindow: 2_000,
            readRange: reader(nil) { reads.append($0) }
        ))

        XCTAssertEqual(window.text, "")
        XCTAssertEqual(window.selection, NSRange(location: 0, length: 0))
        XCTAssertEqual(reads, [], "a zero-length range is the empty string and is never asked of the host")
    }

    func testCaretAtTheStartOfTextReadsOnlyTheTextAfterIt() throws {
        var reads: [NSRange] = []
        let window = try XCTUnwrap(FocusSnapshotResolver.windowedTextSelection(
            selection: NSRange(location: 0, length: 0),
            documentLength: 5,
            contextWindow: 2_000,
            readRange: reader("hello") { reads.append($0) }
        ))

        XCTAssertEqual(window.text, "hello")
        XCTAssertEqual(window.selection, NSRange(location: 0, length: 0))
        XCTAssertEqual(reads, [NSRange(location: 0, length: 5)])
    }

    func testWindowIsBoundedAroundTheSelection() throws {
        let window = try XCTUnwrap(FocusSnapshotResolver.windowedTextSelection(
            selection: NSRange(location: 6, length: 2),
            documentLength: 12,
            contextWindow: 3,
            readRange: reader("abcdefghijkl")
        ))

        XCTAssertEqual(window.text, "defghijk")
        XCTAssertEqual(window.selection, NSRange(location: 3, length: 2))
    }

    func testFailedReadBeforeTheCaretFallsBackToTheFullValue() {
        XCTAssertNil(FocusSnapshotResolver.windowedTextSelection(
            selection: NSRange(location: 3, length: 0),
            documentLength: 5,
            contextWindow: 2_000,
            readRange: reader(nil)
        ))
    }

    func testFailedReadAfterTheCaretKeepsTheWindowWithoutTrailingText() throws {
        let window = try XCTUnwrap(FocusSnapshotResolver.windowedTextSelection(
            selection: NSRange(location: 3, length: 0),
            documentLength: 5,
            contextWindow: 2_000,
            readRange: { range in range.location == 0 ? "hel" : nil }
        ))

        XCTAssertEqual(window.text, "hel")
        XCTAssertEqual(window.selection, NSRange(location: 3, length: 0))
    }
}
