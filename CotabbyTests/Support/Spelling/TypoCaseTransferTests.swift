import XCTest
@testable import Cotabby

/// Tests for copying a typo's capitalization pattern onto its dictionary-cased correction.
final class TypoCaseTransferTests: XCTestCase {
    func test_lowercaseTypoKeepsLowercaseCorrection() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "teh", to: "the"), "the")
    }

    func test_leadingCapitalTypoCapitalizesCorrection() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "Teh", to: "the"), "The")
    }

    func test_allCapsTypoUppercasesCorrection() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "TEH", to: "the"), "THE")
    }

    func test_singleLetterUppercaseIsTreatedAsLeadingCapital() {
        // One uppercase letter is "leading capital", not "all caps", so only the first letter is cased.
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "Eh", to: "the"), "The")
    }

    func test_mixedCaseWithLowercaseLeadIsLeftUnchanged() {
        // Only a leading capital or all-caps are transferred; interior capitals are treated as noise.
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "tEH", to: "the"), "the")
    }

    func test_nonLetterCharactersAreIgnoredWhenReadingThePattern() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "TEH!", to: "the"), "THE")
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "'Teh", to: "the"), "The")
    }

    func test_emptyCorrectionReturnsEmpty() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "Teh", to: ""), "")
    }

    func test_correctionWithoutLettersInSourceReturnedUnchanged() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "123", to: "the"), "the")
    }
}
