import XCTest
@testable import Cotabby

final class TextDirectionDetectorTests: XCTestCase {

    // MARK: - RTL detection

    func test_arabicText_isRTL() {
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("مرحبا بالعالم"))
    }

    func test_hebrewText_isRTL() {
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("שלום עולם"))
    }

    func test_arabicWithTrailingSpaces_isRTL() {
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("مرحبا   "))
    }

    // MARK: - LTR detection

    func test_englishText_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("hello world"))
    }

    func test_emptyString_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft(""))
    }

    func test_whitespaceOnly_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("   "))
    }

    func test_numbersOnly_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("12345"))
    }

    // MARK: - Mixed text (last strong character wins)

    func test_arabicThenEnglish_lastStrongIsLTR() {
        // "hello" is at the end — last strong character is Latin
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("مرحبا hello"))
    }

    func test_englishThenArabic_lastStrongIsRTL() {
        // Arabic is at the end — last strong character is Arabic
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("hello مرحبا"))
    }

    func test_arabicWithTrailingNumbers_isRTL() {
        // Numbers are weak — the last strong character is Arabic
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("مرحبا 123"))
    }

    // MARK: - Presentation forms and directional marks

    func test_hebrewPresentationForm_isRTL() {
        // U+FB2A (HEBREW LETTER SHIN WITH SHIN DOT) sits in the FB1D-FDFF presentation-form
        // block, outside the main Hebrew range, and must still count as strong RTL.
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("\u{FB2A}"))
    }

    func test_arabicPresentationFormB_isRTL() {
        // U+FE8D (ARABIC LETTER ALEF ISOLATED FORM) is in Arabic Presentation Forms-B.
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("\u{FE8D}"))
    }

    func test_rightToLeftMark_isRTL() {
        // An explicit RLM is a strong RTL signal even though it renders as nothing.
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("\u{200F}"))
    }

    func test_leftToRightMark_isLTR() {
        // The LTR mark is the strong-LTR counterpart: it must terminate the scan as LTR.
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("مرحبا\u{200E}"))
    }

    // MARK: - Strong LTR scripts beyond lowercase Basic Latin

    func test_uppercaseLatin_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("WORLD"))
    }

    func test_latinExtended_isLTR() {
        // U+00E9 (e with acute) is in the Latin Extended range, not Basic Latin.
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("caf\u{00E9}"))
    }

    func test_greek_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("αβγ"))
    }

    func test_cyrillic_isLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("привет"))
    }

    func test_cjkIdeographs_areTreatedAsLTR() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("中文"))
    }
}
