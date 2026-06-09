import XCTest
@testable import Cotabby

final class SpellingDictionaryResourceTests: XCTestCase {
    func test_everyCatalogDictionaryIsBundledAndParseable() throws {
        for language in SpellingDictionaryLanguage.allCases {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: language.resourceName,
                    withExtension: "txt"
                ),
                "Missing bundled \(language.displayName) dictionary"
            )
            let firstLine = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", maxSplits: 1)
                .first
            let columns = firstLine?.split(whereSeparator: \.isWhitespace)

            XCTAssertEqual(columns?.count, 2, "Malformed \(language.displayName) dictionary")
            XCTAssertNotNil(columns.flatMap { Int64($0[1]) })
        }
    }
}
