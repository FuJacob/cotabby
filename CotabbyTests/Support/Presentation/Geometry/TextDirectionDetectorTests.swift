import XCTest
@testable import Cotabby

/// Tests for the caret-side direction heuristic: scanning backwards, the last strong directional
/// character wins, and weak/neutral characters (digits, spaces, punctuation) are skipped. Text with
/// no strong character defaults to left-to-right.
final class TextDirectionDetectorTests: XCTestCase {

    func test_rightToLeftInputs() {
        let cases: [(label: String, text: String)] = [
            ("Arabic", "مرحبا بالعالم"),
            ("Hebrew", "שלום עולם"),
            ("Syriac (inside the contiguous 0590-08FF block)", "\u{0710}"),
            ("Hebrew presentation form (FB1D-FDFF)", "\u{FB2A}"),
            ("Arabic Presentation Forms-B (FE70-FEFF)", "\u{FE8D}"),
            ("right-to-left mark", "\u{200F}"),
            ("Arabic letter mark", "\u{061C}"),
            ("trailing spaces are skipped", "مرحبا   "),
            ("trailing digits are weak", "مرحبا 123"),
            ("trailing punctuation is neutral", "مرحبا!?"),
            ("last strong character is Arabic", "hello مرحبا")
        ]

        for (label, text) in cases {
            XCTAssertTrue(TextDirectionDetector.isRightToLeft(text), label)
        }
    }

    func test_leftToRightInputs() {
        let cases: [(label: String, text: String)] = [
            ("empty", ""),
            ("whitespace only", "   "),
            ("digits only", "12345"),
            ("punctuation only", "?!..."),
            ("lowercase Latin", "hello world"),
            ("uppercase Latin", "WORLD"),
            ("Latin Extended (U+00E9)", "caf\u{00E9}"),
            ("Greek", "αβγ"),
            ("Cyrillic", "привет"),
            ("CJK ideographs are treated as LTR", "中文"),
            ("left-to-right mark ends the scan", "مرحبا\u{200E}"),
            ("last strong character is Latin", "مرحبا hello")
        ]

        for (label, text) in cases {
            XCTAssertFalse(TextDirectionDetector.isRightToLeft(text), label)
        }
    }

    func test_rtlBlockBoundariesAreExact() {
        // Just outside each RTL range the scalar is not strong in either direction, so a lone
        // boundary character falls through to the LTR default.
        for scalar in ["\u{058F}", "\u{0900}", "\u{FB1C}", "\u{FE6F}"] {
            XCTAssertFalse(
                TextDirectionDetector.isRightToLeft(scalar),
                "U+\(String(scalar.unicodeScalars.first!.value, radix: 16, uppercase: true))"
            )
        }
        for scalar in ["\u{0590}", "\u{08FF}", "\u{FB1D}", "\u{FDFF}", "\u{FE70}", "\u{FEFF}"] {
            XCTAssertTrue(
                TextDirectionDetector.isRightToLeft(scalar),
                "U+\(String(scalar.unicodeScalars.first!.value, radix: 16, uppercase: true))"
            )
        }
    }
}
