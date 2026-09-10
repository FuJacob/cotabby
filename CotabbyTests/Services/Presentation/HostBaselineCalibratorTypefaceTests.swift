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

    func test_aFieldWithNoRecordIsAlwaysMeasured() {
        XCTAssertTrue(HostBaselineCalibrator.wantsTypefaceMatch(known: nil, lineText: "Hi"))
        XCTAssertTrue(HostBaselineCalibrator.wantsTypefaceMatch(known: nil, lineText: nil))
    }

    func test_aSettledRecordIsNeverReMeasured() {
        let settled = record(score: 0.97, textLength: 5)
        XCTAssertFalse(HostBaselineCalibrator.wantsTypefaceMatch(known: settled, lineText: String(repeating: "a", count: 60)))
    }

    func test_aWeakRecordIsRetriedOnlyOnAMateriallyLongerLine() {
        // ChatGPT's first match came from five characters at 0.914; a longer line is better evidence.
        let weak = record(score: 0.914, textLength: 5)
        XCTAssertFalse(HostBaselineCalibrator.wantsTypefaceMatch(known: weak, lineText: "Hi there"))
        XCTAssertTrue(HostBaselineCalibrator.wantsTypefaceMatch(known: weak, lineText: "Hi there, thanks"))
        XCTAssertFalse(HostBaselineCalibrator.wantsTypefaceMatch(known: weak, lineText: nil))
    }

    func test_aFieldThatNeverMatchesStopsBeingAskedAfterTheCap() {
        XCTAssertTrue(HostBaselineCalibrator.wantsTypefaceMatch(known: nil, misses: HostBaselineCalibrator.maximumTypefaceAttempts - 1, lineText: "enough text here"))
        XCTAssertFalse(HostBaselineCalibrator.wantsTypefaceMatch(known: nil, misses: HostBaselineCalibrator.maximumTypefaceAttempts, lineText: "enough text here"))
    }

    func test_reMeasurementStopsAtTheAttemptCap() {
        let tired = record(score: 0.9, textLength: 5, attempts: HostBaselineCalibrator.maximumTypefaceAttempts)
        XCTAssertFalse(HostBaselineCalibrator.wantsTypefaceMatch(known: tired, lineText: String(repeating: "a", count: 40)))
    }

    /// Measured in Obsidian: the system face scored 0.943 on one strip; on the next strip Arial
    /// scored 0.980 while the system face itself scored 0.969. Comparing 0.980 with the recorded
    /// 0.943 swapped the right face for a wrong one; the comparison must be made on the same strip.
    func test_aLaterStripReplacesTheFaceOnlyWhenItBeatsItThere() {
        let known = record(score: 0.943, textLength: 30, fontName: ".AppleSystemUIFont")
        let ranking = [score("ArialMT", "Arial", 16.75, 0.980), score("Helvetica", "Helvetica", 16.75, 0.975), score(".AppleSystemUIFont", ".AppleSystemUIFont", 16, 0.969)]
        let kept = HostBaselineCalibrator.updatedTypefaceRecord(known: known, match: match("ArialMT", "Arial", 16.75, 0.980), ranking: ranking, textLength: 40)
        XCTAssertEqual(kept?.fontName, ".AppleSystemUIFont")
        XCTAssertEqual(kept?.attempts, 2)
        XCTAssertEqual(kept?.textLength, 40)

        let decisive = [score("ArialMT", "Arial", 16.75, 0.980), score(".AppleSystemUIFont", ".AppleSystemUIFont", 16, 0.90)]
        let replaced = HostBaselineCalibrator.updatedTypefaceRecord(known: known, match: match("ArialMT", "Arial", 16.75, 0.980), ranking: decisive, textLength: 40)
        XCTAssertEqual(replaced?.fontName, "ArialMT")
        XCTAssertEqual(replaced?.pointSize, 16.75)
    }

    func test_theSameFaceAgainKeepsItsSizeAndRaisesItsScore() {
        let known = record(score: 0.943, textLength: 30, fontName: ".AppleSystemUIFont")
        let again = HostBaselineCalibrator.updatedTypefaceRecord(
            known: known, match: match(".AppleSystemUIFont", ".AppleSystemUIFont", 16.25, 0.97),
            ranking: [score(".AppleSystemUIFont", ".AppleSystemUIFont", 16.25, 0.97)], textLength: 36
        )
        XCTAssertEqual(again?.pointSize, 16)
        XCTAssertEqual(again?.score ?? 0, 0.97, accuracy: 0.0001)
    }

    func test_aFirstMatchIsAdoptedAndAMissLeavesNoRecord() {
        XCTAssertNil(HostBaselineCalibrator.updatedTypefaceRecord(known: nil, match: nil, ranking: [], textLength: 10))
        let first = HostBaselineCalibrator.updatedTypefaceRecord(known: nil, match: match("Georgia", "Georgia", 18, 0.99), ranking: [], textLength: 12)
        XCTAssertEqual(first?.fontName, "Georgia")
        XCTAssertEqual(first?.attempts, 1)
        let miss = HostBaselineCalibrator.updatedTypefaceRecord(known: first, match: nil, ranking: [], textLength: 20)
        XCTAssertEqual(miss?.fontName, "Georgia")
        XCTAssertEqual(miss?.attempts, 2)
    }

    func test_typefaceKnowledgeIsKeyedByFieldAlone() {
        // A size guess that changes with the caret box must not open a second slot for the field.
        XCTAssertEqual(
            HostBaselineCalibrator.TypefaceKey(focusedInputIdentityKey: 7),
            HostBaselineCalibrator.TypefaceKey(focusedInputIdentityKey: 7)
        )
    }

    func test_captureRectsAreSnappedOutwardToWholePixels() {
        let snapped = HostBaselineCalibrator.snappedToPixels(CGRect(x: 279, y: 915.5, width: 227.75, height: 22), scale: 2)
        XCTAssertEqual(snapped.minX, 279); XCTAssertEqual(snapped.minY, 915.5)
        XCTAssertEqual(snapped.maxX, 507); XCTAssertEqual(snapped.maxY, 937.5)
        let odd = HostBaselineCalibrator.snappedToPixels(CGRect(x: 10.3, y: 4.7, width: 10.1, height: 3.1), scale: 2)
        XCTAssertEqual(odd.minX, 10); XCTAssertEqual(odd.maxX, 20.5); XCTAssertEqual(odd.minY, 4.5); XCTAssertEqual(odd.maxY, 8)
    }

    func test_aLoneGlyphIsNotEnoughInkForABaseline() {
        // The lone "A" strip measured in Obsidian carried 170 ink pixels; a word carries hundreds.
        XCTAssertFalse(HostBaselineCalibrator.hasEnoughInk(.init(baselineRow: 34, bodyTopRow: 15, inkPixelCount: 170)))
        XCTAssertTrue(HostBaselineCalibrator.hasEnoughInk(.init(baselineRow: 34, bodyTopRow: 15, inkPixelCount: 600)))
    }
}
