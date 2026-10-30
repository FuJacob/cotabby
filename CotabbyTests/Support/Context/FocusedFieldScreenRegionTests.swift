import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the focused field's region inside a screenshot: the display-to-Vision mapping, the
/// clip to the capture, which OCR lines the field claims, and the pixel rectangle the extraction
/// cache leaves out of its change detection.
final class FocusedFieldScreenRegionTests: XCTestCase {
    private typealias Line = OCRTextHygiene.OCRLine

    // MARK: - Mapping into Vision space

    func test_mapsATopLeftDisplayFrameIntoBottomLeftUnitSpace() throws {
        // A composer near the bottom of a 1000x500pt capture: 200pt in, 50pt above the bottom edge.
        let region = try XCTUnwrap(FocusedFieldScreenRegion(
            fieldFrame: CGRect(x: 300, y: 600, width: 400, height: 50),
            captureRect: CGRect(x: 100, y: 200, width: 1000, height: 500)
        ))

        assertEqual(region.bounds, CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1))
    }

    func test_clipsAFieldThatOverflowsTheCapture() throws {
        // A scrolled text view reports its whole content frame, far taller than the window.
        let region = try XCTUnwrap(FocusedFieldScreenRegion(
            fieldFrame: CGRect(x: 300, y: -5000, width: 400, height: 5600),
            captureRect: CGRect(x: 100, y: 200, width: 1000, height: 500)
        ))

        assertEqual(region.bounds, CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.8))
    }

    func test_aFieldOutsideTheCaptureOrWithoutAreaHasNoRegion() {
        let capture = CGRect(x: 100, y: 200, width: 1000, height: 500)
        // The endpoint profile captures the band above the field, so the field only touches it.
        XCTAssertNil(FocusedFieldScreenRegion(fieldFrame: CGRect(x: 300, y: 700, width: 400, height: 50), captureRect: capture))
        XCTAssertNil(FocusedFieldScreenRegion(fieldFrame: CGRect(x: 300, y: 600, width: 0, height: 50), captureRect: capture))
        XCTAssertNil(FocusedFieldScreenRegion(fieldFrame: .null, captureRect: capture))
        XCTAssertNil(FocusedFieldScreenRegion(fieldFrame: CGRect(x: 300, y: 600, width: 400, height: 50), captureRect: .zero))
    }

    // MARK: - Which lines the field claims

    func test_claimsLinesByTheCenterOfTheirBox() throws {
        let region = try XCTUnwrap(FocusedFieldScreenRegion(bounds: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1)))

        XCTAssertTrue(region.contains(line("HOW IS GOING", x: 0.25, y: 0.12, width: 0.2)))
        // Vision can merge the typed text with the composer's "+" button just left of the field.
        XCTAssertTrue(region.contains(line("+ HOW IS GOING", x: 0.18, y: 0.12, width: 0.3)))
        // The model picker below the field overlaps its edge but is centered outside it.
        XCTAssertFalse(region.contains(line("Opus Extra Auto", x: 0.3, y: 0.08, width: 0.2)))
        XCTAssertFalse(region.contains(Line(text: "No geometry", confidence: 1)))
    }

    func test_excludingKeepsTheConversationInReadingOrder() throws {
        let region = try XCTUnwrap(FocusedFieldScreenRegion(bounds: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.1)))
        let lines = [
            line("The earlier message explains the project", x: 0.2, y: 0.6, width: 0.5),
            line("The newest message asks about the deadline", x: 0.2, y: 0.3, width: 0.5),
            line("Sure, the deadline is Fri", x: 0.21, y: 0.12, width: 0.3),
            Line(text: "Text-only fixture line", confidence: 1)
        ]

        XCTAssertEqual(region.excluding(lines).map(\.text), [
            "The earlier message explains the project",
            "The newest message asks about the deadline",
            "Text-only fixture line"
        ])
    }

    // MARK: - Pixel rectangle for the extraction cache

    func test_pixelRectPutsTheTopRowFirst() throws {
        // The bottom quarter of the middle half of a 40x20 image.
        let region = try XCTUnwrap(FocusedFieldScreenRegion(bounds: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.25)))

        XCTAssertEqual(region.pixelRect(width: 40, height: 20), .init(rows: 15..<20, columns: 10..<30))
    }

    func test_pixelRectRoundsFractionalEdgesOutward() throws {
        // Edges at 1.25/3.75 columns and 3.125/5 rows (top-down) of a 10x10 image.
        let region = try XCTUnwrap(FocusedFieldScreenRegion(bounds: CGRect(x: 0.125, y: 0.5, width: 0.25, height: 0.1875)))

        XCTAssertEqual(region.pixelRect(width: 10, height: 10), .init(rows: 3..<5, columns: 1..<4))
    }

    func test_pixelRectOfAWholeImageFieldCoversEveryPixel() throws {
        let region = try XCTUnwrap(FocusedFieldScreenRegion(bounds: CGRect(x: -1, y: -1, width: 3, height: 3)))

        XCTAssertEqual(region.pixelRect(width: 7, height: 3), .init(rows: 0..<3, columns: 0..<7))
        XCTAssertEqual(region.pixelRect(width: 0, height: 0), .init(rows: 0..<0, columns: 0..<0))
    }

    // MARK: - Helpers

    private func line(_ text: String, x: Double, y: Double, width: Double) -> Line {
        Line(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: width, height: 0.03))
    }

    private func assertEqual(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, file: file, line: line)
    }
}
