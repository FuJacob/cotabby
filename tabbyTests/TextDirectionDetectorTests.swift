import XCTest
@testable import tabby

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
}
