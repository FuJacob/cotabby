import XCTest
@testable import Cotabby

final class WordCountFormatterTests: XCTestCase {
    func test_zeroReturnsNil() {
        XCTAssertNil(WordCountFormatter.compactLabel(for: 0))
    }

    func test_negativeReturnsNil() {
        XCTAssertNil(WordCountFormatter.compactLabel(for: -5))
    }

    func test_singleDigit() {
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 1), "1")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 9), "9")
    }

    func test_hundredsShowRawNumber() {
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 42), "42")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 999), "999")
    }

    func test_thousandsShowOneDecimal() {
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 1_000), "1.0K")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 1_500), "1.5K")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 9_900), "9.9K")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 9_999), "10.0K")
    }

    func test_tenThousandsShowWholeK() {
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 10_000), "10K")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 50_000), "50K")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 999_999), "999K")
    }

    func test_millionsShowOneDecimal() {
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 1_000_000), "1.0M")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 5_500_000), "5.5M")
    }

    func test_tenMillionsShowWholeM() {
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 10_000_000), "10M")
        XCTAssertEqual(WordCountFormatter.compactLabel(for: 42_000_000), "42M")
    }
}
