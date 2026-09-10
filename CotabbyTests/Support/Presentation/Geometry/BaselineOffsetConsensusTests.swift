import XCTest
@testable import Cotabby

/// The rule that keeps every line of a field on one baseline. The numbers are the ones the
/// alignment harness measured in Obsidian: line 1 read 16.0 and was right, line 2 read 15.0 and
/// lifted the ghost a full point.
final class BaselineOffsetConsensusTests: XCTestCase {
    func testFirstReadingDefinesTheField() {
        let consensus = BaselineOffsetConsensus(first: 16)
        XCTAssertEqual(consensus.value, 16)
        XCTAssertNil(consensus.dissent)
    }

    func testALoneDissentingLineDoesNotMoveTheField() {
        var consensus = BaselineOffsetConsensus(first: 16)
        XCTAssertFalse(consensus.offer(15))
        XCTAssertEqual(consensus.value, 16, "one stray line must render on the field's baseline")
        XCTAssertEqual(consensus.dissent, 15)
    }

    func testAnAgreeingReadingClearsTheDissent() {
        var consensus = BaselineOffsetConsensus(first: 16)
        _ = consensus.offer(15)
        XCTAssertFalse(consensus.offer(16.5))
        XCTAssertNil(consensus.dissent)
        XCTAssertEqual(consensus.value, 16)
    }

    /// A stray FIRST line is the one case the field should move: two later lines that agree with
    /// each other outvote it, and the ghost moves once onto the real baseline.
    func testTwoAgreeingDissentsCorrectAStrayFirstReadingOnce() {
        var consensus = BaselineOffsetConsensus(first: 11)
        XCTAssertFalse(consensus.offer(15))
        XCTAssertTrue(consensus.offer(15.25))
        XCTAssertEqual(consensus.value, 15.25)
        XCTAssertTrue(consensus.hasCorrected)
        // Never a second correction: the value must not drift sample by sample.
        XCTAssertFalse(consensus.offer(12))
        XCTAssertFalse(consensus.offer(12.1))
        XCTAssertEqual(consensus.value, 15.25)
    }

    func testDissentsThatDisagreeWithEachOtherNeverCorrect() {
        var consensus = BaselineOffsetConsensus(first: 16)
        XCTAssertFalse(consensus.offer(13))
        XCTAssertFalse(consensus.offer(19))
        XCTAssertEqual(consensus.value, 16)
    }
}
