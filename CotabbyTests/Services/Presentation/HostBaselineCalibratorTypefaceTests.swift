import XCTest
@testable import Cotabby

/// The calibrator decides when a field's face is worth re-measuring and when a new reading may
/// replace the old one; these rules are what keep the ghost's face from flipping.
final class HostBaselineCalibratorTypefaceTests: XCTestCase {
    private func record(score: Double, textLength: Int, attempts: Int = 1, fontName: String = "Helvetica") -> HostBaselineCalibrator.TypefaceMatchRecord {
        HostBaselineCalibrator.TypefaceMatchRecord(fontName: fontName, pointSize: 16, score: score, textLength: textLength, attempts: attempts)
    }

    private func score(_ fontName: String, _ family: String, _ size: CGFloat, _ score: Double) -> TypefaceMatcher.Score {
        TypefaceMatcher.Score(fontName: fontName, familyName: family, pointSize: size, score: score)
    }

    private func match(_ fontName: String, _ family: String, _ size: CGFloat, _ value: Double) -> TypefaceMatcher.Match {
        TypefaceMatcher.Match(fontName: fontName, familyName: family, pointSize: size, score: value, runnerUpScore: 0.5, systemScore: 0.5)
    }

    private typealias Progress = HostBaselineCalibrator.TypefaceProgress

    func test_aFieldWithNoRecordIsAlwaysMeasured() {
        XCTAssertTrue(Progress.initial.wantsMatch(lineText: "Hi"))
        XCTAssertTrue(Progress.initial.wantsMatch(lineText: nil))
    }

    func test_aSettledRecordIsNeverReMeasured() {
        let settled = record(score: 0.97, textLength: 5)
        XCTAssertFalse(Progress.matched(settled).wantsMatch(lineText: String(repeating: "a", count: 60)))
    }

    func test_aWeakRecordIsRetriedOnlyOnAMateriallyLongerLine() {
        // ChatGPT's first match came from five characters at 0.914; a longer line is better evidence.
        let weak = record(score: 0.914, textLength: 5)
        XCTAssertFalse(Progress.matched(weak).wantsMatch(lineText: "Hi there"))
        XCTAssertTrue(Progress.matched(weak).wantsMatch(lineText: "Hi there, thanks"))
        XCTAssertFalse(Progress.matched(weak).wantsMatch(lineText: nil))
    }

    func test_aFieldThatNeverMatchesStopsBeingAskedAfterTheCap() {
        XCTAssertTrue(Progress.unmatched(misses: HostBaselineCalibrator.maximumTypefaceAttempts - 1).wantsMatch(lineText: "enough text here"))
        XCTAssertFalse(Progress.unmatched(misses: HostBaselineCalibrator.maximumTypefaceAttempts).wantsMatch(lineText: "enough text here"))
    }

    func test_reMeasurementStopsAtTheAttemptCap() {
        let tired = record(score: 0.9, textLength: 5, attempts: HostBaselineCalibrator.maximumTypefaceAttempts)
        XCTAssertFalse(Progress.matched(tired).wantsMatch(lineText: String(repeating: "a", count: 40)))
    }

    /// Measured in Obsidian: the system face scored 0.943 on one strip; on the next strip Arial
    /// scored 0.980 while the system face itself scored 0.969. Comparing 0.980 with the recorded
    /// 0.943 swapped the right face for a wrong one; the comparison must be made on the same strip.
    func test_aLaterStripReplacesTheFaceOnlyWhenItBeatsItThere() {
        let known = record(score: 0.943, textLength: 30, fontName: ".AppleSystemUIFont")
        let ranking = [score("ArialMT", "Arial", 16.75, 0.980), score("Helvetica", "Helvetica", 16.75, 0.975), score(".AppleSystemUIFont", ".AppleSystemUIFont", 16, 0.969)]
        let kept = Progress.matched(known).advanced(match: match("ArialMT", "Arial", 16.75, 0.980), ranking: ranking, textLength: 40).record
        XCTAssertEqual(kept?.fontName, ".AppleSystemUIFont")
        XCTAssertEqual(kept?.attempts, 2)
        XCTAssertEqual(kept?.textLength, 40)

        let decisive = [score("ArialMT", "Arial", 16.75, 0.980), score(".AppleSystemUIFont", ".AppleSystemUIFont", 16, 0.90)]
        let replaced = Progress.matched(known).advanced(match: match("ArialMT", "Arial", 16.75, 0.980), ranking: decisive, textLength: 40).record
        XCTAssertEqual(replaced?.fontName, "ArialMT")
        XCTAssertEqual(replaced?.pointSize, 16.75)
    }

    func test_theSameFaceAgainKeepsItsSizeAndRaisesItsScore() {
        let known = record(score: 0.943, textLength: 30, fontName: ".AppleSystemUIFont")
        let again = Progress.matched(known).advanced(
            match: match(".AppleSystemUIFont", ".AppleSystemUIFont", 16.25, 0.97),
            ranking: [score(".AppleSystemUIFont", ".AppleSystemUIFont", 16.25, 0.97)], textLength: 36
        ).record
        XCTAssertEqual(again?.pointSize, 16)
        XCTAssertEqual(again?.score ?? 0, 0.97, accuracy: 0.0001)
    }

    func test_aFirstMatchIsAdoptedAndAMissLeavesNoRecord() {
        XCTAssertNil(Progress.initial.advanced(match: nil, ranking: [], textLength: 10).record)
        let first = Progress.initial.advanced(match: match("Georgia", "Georgia", 18, 0.99), ranking: [], textLength: 12)
        XCTAssertEqual(first.record?.fontName, "Georgia")
        XCTAssertEqual(first.record?.attempts, 1)
        let miss = first.advanced(match: nil, ranking: [], textLength: 20).record
        XCTAssertEqual(miss?.fontName, "Georgia")
        XCTAssertEqual(miss?.attempts, 2)
    }

    /// The miss count is what stops an unmatchable field being asked for ever; it must only rise on
    /// a strip that was real evidence, and a first match must end it.
    func test_onlyAStripThatWasEvidenceCountsAsAMiss() {
        func misses(_ progress: Progress) -> Int? {
            if case .unmatched(let misses) = progress { return misses }
            return nil
        }
        let searched = Progress.initial.advanced(match: nil, ranking: [], textLength: 10, isEvidence: true)
        XCTAssertEqual(misses(searched), 1)
        let declined = searched.advanced(match: nil, ranking: [], textLength: 10, isEvidence: false)
        XCTAssertEqual(misses(declined), 1, "a strip that could not have named a face is not a miss")

        var exhausted = Progress.initial
        for _ in 0..<HostBaselineCalibrator.maximumTypefaceAttempts {
            XCTAssertTrue(exhausted.wantsMatch(lineText: "enough text here"))
            exhausted = exhausted.advanced(match: nil, ranking: [], textLength: 16)
        }
        XCTAssertFalse(exhausted.wantsMatch(lineText: "enough text here"))

        let matched = searched.advanced(match: match("Georgia", "Georgia", 18, 0.99), ranking: [], textLength: 12)
        XCTAssertNil(misses(matched))
        XCTAssertEqual(matched.record?.attempts, 1)
    }
}
