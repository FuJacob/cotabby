import XCTest
@testable import Cotabby

/// The preview's warning says exactly what the rewrite changed, so the user can decide whether to
/// "Replace anyway": when "1000%" comes back as "100%", a bare list of new terms ("Not in your text:
/// 100") would not say that the number had changed.
final class RewriteChangeWarningTests: XCTestCase {
    func test_changedNumberNamesBothValues() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "trust me, I am 1000% sure", rewrite: "Trust me, I'm 100% sure.",
                                         unsupported: ["100"]),
            "The number changed: you wrote 1000, the rewrite says 100."
        )
    }

    func test_severalChangedNumbers() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "dinner on the 27th or 28th", rewrite: "dinner on the 26th or 29th",
                                         unsupported: ["26", "29"]),
            "Numbers changed: you wrote 27, 28; the rewrite says 26, 29."
        )
    }

    func test_addedNumberWithNothingRemoved() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "see you soon", rewrite: "see you at 5", unsupported: ["5"]),
            "The rewrite adds the number 5, which isn't in your text."
        )
    }

    func test_addedName() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "let me know", rewrite: "Let me know, Sam.", unsupported: ["Sam"]),
            "The rewrite adds “Sam”, which isn't in your text."
        )
    }

    func test_severalAddedNames() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "let me know", rewrite: "Let me know, Sam and Jo.",
                                         unsupported: ["Sam", "Jo"]),
            "The rewrite adds “Sam”, “Jo”, which aren't in your text."
        )
    }

    func test_numberAndNameTogether() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "meet at 10", rewrite: "Meet Sam at 11.", unsupported: ["11", "Sam"]),
            "The number changed: you wrote 10, the rewrite says 11. The rewrite adds “Sam”, which isn't in your text."
        )
    }

    func test_nothingUnsupportedIsNoWarning() {
        XCTAssertNil(RewriteChangeWarning.message(selection: "a", rewrite: "b", unsupported: []))
    }

    func test_changedDecimalIsNamedAsANumber() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "it takes 3.5 hours", rewrite: "It takes 35 hours.", unsupported: ["35"]),
            "The number changed: you wrote 3.5, the rewrite says 35."
        )
    }
}
