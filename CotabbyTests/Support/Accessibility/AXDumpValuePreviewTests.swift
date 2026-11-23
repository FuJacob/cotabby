import XCTest
@testable import Cotabby

/// Locks what the developer AX tree dump prints for an element's value: a bounded, one-line
/// preview for ordinary fields, and nothing of a secure field's value, not even its length.
final class AXDumpValuePreviewTests: XCTestCase {
    func test_line_redactsASecureValueEntirely() {
        let line = AXDumpValuePreview.line(for: "hunter2-correct-horse", isSecure: true)

        XCTAssertEqual(line, AXDumpValuePreview.redactedValue)
        XCTAssertFalse(line.contains("hunter2"))
        XCTAssertFalse(line.contains("len="), "A password's length is not printed either")
    }

    func test_line_quotesAShortValueWithItsLength() {
        XCTAssertEqual(AXDumpValuePreview.line(for: "Hello", isSecure: false), "\"Hello\" (len=5)")
    }

    func test_line_cutsALongValueAndKeepsTheFullLength() {
        let text = String(repeating: "a", count: 100)

        let line = AXDumpValuePreview.line(for: text, isSecure: false)

        XCTAssertEqual(line, "\"" + String(repeating: "a", count: AXDumpValuePreview.previewLimit) + "…\" (len=100)")
    }

    func test_line_escapesNewlinesSoEachNodeStaysOneLine() {
        XCTAssertEqual(AXDumpValuePreview.line(for: "one\ntwo", isSecure: false), "\"one\\ntwo\" (len=7)")
    }
}
