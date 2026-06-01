import XCTest
@testable import Cotabby

/// Pure tests for the no-repeat-ngram block set. Operates on token ids only, so cases are written as
/// small id sequences with the expected blocked followers.
final class RepetitionGuardTests: XCTestCase {

    func test_ngramSizeBelowTwo_blocksNothing() {
        // A 1-gram block would forbid every token that ever appeared; the guard refuses that.
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [1, 1, 2], ngramSize: 1), [])
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [1, 1, 2], ngramSize: 0), [])
    }

    func test_historyShorterThanPrefix_blocksNothing() {
        // n=3 needs a 2-token pending prefix; one token cannot form it.
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [7], ngramSize: 3), [])
    }

    func test_noRepeatedPrefix_blocksNothing() {
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [1, 2, 3], ngramSize: 3), [])
    }

    func test_repeatedPrefix_blocksItsFollower() {
        // Pending prefix [1,2] occurred earlier at index 0, followed by 1, so emitting 1 would repeat
        // the trigram [1,2,1]. Block 1.
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [1, 2, 1, 2], ngramSize: 3), [1])
    }

    func test_singleTokenRun_blocksAfterThreeWithTrigram() {
        // Three identical tokens are allowed; the fourth would repeat the trigram [5,5,5].
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [5, 5], ngramSize: 3), [])
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [5, 5, 5], ngramSize: 3), [5])
    }

    func test_multipleFollowers_allBlocked() {
        // [1,2] appears twice, followed by 9 then 8; both followers are blocked.
        let blocked = RepetitionGuard.blockedTokens(history: [1, 2, 9, 1, 2, 8, 1, 2], ngramSize: 3)
        XCTAssertEqual(blocked, [9, 8])
    }

    func test_bigramOrder_blocksRepeatedBigram() {
        // n=2: pending prefix is the last single token. [1] occurred at index 0 followed by 2, so
        // emitting 2 would repeat the bigram [1,2].
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [1, 2, 1], ngramSize: 2), [2])
    }

    func test_prefixPresentButNotPending_notBlocked() {
        // [1,2] appears early but the pending prefix is [3,4]; nothing repeats, so nothing is blocked.
        XCTAssertEqual(RepetitionGuard.blockedTokens(history: [1, 2, 9, 3, 4], ngramSize: 3), [])
    }
}
