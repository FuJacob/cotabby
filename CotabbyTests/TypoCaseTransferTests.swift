import XCTest
@testable import Cotabby

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

    func test_emptyCorrectionReturnsEmpty() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "Teh", to: ""), "")
    }

    func test_correctionWithoutLettersInSourceReturnedUnchanged() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "123", to: "the"), "the")
    }
}
