import XCTest
@testable import Cotabby

/// Tests for the separator parser shared by the unit and currency families.
final class ConversionSeparatorTests: XCTestCase {
    func test_splitsOnEachSupportedSeparator() {
        let cases: [(query: String, left: String, right: String)] = [
            ("10km->mi", "10km", "mi"),
            ("10km→mi", "10km", "mi"),
            ("10 km to mi", "10 km", "mi"),
            ("10 km TO mi", "10 km", "mi")
        ]
        for (query, left, right) in cases {
            let split = ConversionSeparator.split(query)
            XCTAssertEqual(split?.left, left, query)
            XCTAssertEqual(split?.right, right, query)
        }
    }

    func test_sidesAreReturnedUntrimmed() {
        // Callers own trimming; the parser only cuts at the separator.
        let split = ConversionSeparator.split("10 km -> mi")
        XCTAssertEqual(split?.left, "10 km ")
        XCTAssertEqual(split?.right, " mi")
    }

    func test_arrowTakesPrecedenceOverSpacedTo() {
        let split = ConversionSeparator.split("a to b->c")
        XCTAssertEqual(split?.left, "a to b")
        XCTAssertEqual(split?.right, "c")
    }

    func test_toMustBeSpaceDelimited() {
        // "to" inside a word (or without surrounding spaces) is not a separator.
        XCTAssertNil(ConversionSeparator.split("tomato"))
        XCTAssertNil(ConversionSeparator.split("10kmtomi"))
        XCTAssertNil(ConversionSeparator.split("10km mi"))
    }
}
