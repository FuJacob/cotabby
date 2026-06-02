import XCTest
@testable import Cotabby

/// Tests for the byte-exact required-prefix admissibility rule used by the constrained decoder.
///
/// The invariant: a token is admissible iff it completes the remaining prefix (token starts with the
/// prefix) or is a step toward it (prefix starts with the token); anything else diverges and is
/// rejected. The rule operates on raw bytes so it stays correct when a token splits a multi-byte
/// UTF-8 scalar.
final class RequiredPrefixConstraintTests: XCTestCase {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    func test_emptyRemainingPrefix_admitsAnyToken() {
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: [], tokenBytes: bytes("anything")),
            .satisfied
        )
    }

    func test_tokenExactlyCompletesPrefix() {
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: bytes("ation"), tokenBytes: bytes("ation")),
            .satisfied
        )
    }

    func test_tokenCompletesAndOvershootsPrefix() {
        // A token longer than the requirement is fine as long as it starts with the whole prefix.
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: bytes("at"), tokenBytes: bytes("ation")),
            .satisfied
        )
    }

    func test_shorterTokenAdvancesPrefix() {
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: bytes("ation"), tokenBytes: bytes("at")),
            .advanced(remaining: bytes("ion"))
        )
    }

    func test_singleByteTokenAdvancesPrefix() {
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: bytes("ation"), tokenBytes: bytes("a")),
            .advanced(remaining: bytes("tion"))
        )
    }

    func test_divergingLongerTokenIsRejected() {
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: bytes("at"), tokenBytes: bytes("be")),
            .rejected
        )
    }

    func test_divergingShorterTokenIsRejected() {
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: bytes("ation"), tokenBytes: bytes("x")),
            .rejected
        )
    }

    func test_multiByteScalarSplitAcrossTokens() {
        // "é" is two UTF-8 bytes (0xC3 0xA9). A token carrying only the lead byte must advance by it,
        // and only the correct continuation byte may follow.
        let prefix = bytes("é")
        XCTAssertEqual(prefix, [0xC3, 0xA9])

        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: prefix, tokenBytes: [0xC3]),
            .advanced(remaining: [0xA9])
        )
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: [0xA9], tokenBytes: [0xC3]),
            .rejected
        )
        XCTAssertEqual(
            RequiredPrefixConstraint.step(remainingPrefix: prefix, tokenBytes: prefix),
            .satisfied
        )
    }

    func test_admitsPredicateMatchesStep() {
        XCTAssertTrue(RequiredPrefixConstraint.admits(remainingPrefix: bytes("ation"), tokenBytes: bytes("a")))
        XCTAssertTrue(RequiredPrefixConstraint.admits(remainingPrefix: bytes("at"), tokenBytes: bytes("ation")))
        XCTAssertFalse(RequiredPrefixConstraint.admits(remainingPrefix: bytes("ation"), tokenBytes: bytes("x")))
        XCTAssertTrue(RequiredPrefixConstraint.admits(remainingPrefix: [], tokenBytes: bytes("x")))
    }
}
