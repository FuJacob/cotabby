import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the caret-to-text-run mapping used by the child-run geometry path (Gmail/Outlook-class
/// editors). The mapping must be alignment-based: Chromium parent values separate blocks with
/// newlines (and sometimes nothing at all) that the run texts do not contain, so cumulative-length
/// math drifts the caret into the wrong run — one visual line per unaccounted character. Real
/// captured values also mix non-breaking and plain spaces and fuse adjacent blocks into clumps
/// like "i'mhi", which is what the boundary rule and the windowed second pass defend against.
@MainActor
final class CaretRunPlacementTests: XCTestCase {
    private typealias Placement = AXTextGeometryResolver.CaretRunPlacement

    private func placement(
        runs: [String],
        parent: String,
        caret: Int
    ) -> Placement? {
        AXTextGeometryResolver.caretRunPlacement(
            runTexts: runs,
            parentText: parent,
            caretOffset: caret
        )
    }

    func test_placement_newlineSeparatorsDoNotDriftTheCaretIntoLaterRuns() {
        // Caret at the start of "bb" (offset 3, past "aa\n"). Cumulative math would land it
        // mid-"bb" because the separator newline inflates the offset; alignment must not.
        let result = placement(runs: ["aa", "bb"], parent: "aa\nbb", caret: 3)

        XCTAssertEqual(result, Placement(runIndex: 1, fraction: 0, mode: .aligned))
    }

    func test_placement_multipleParagraphSeparatorsStayExact() {
        // End of the last paragraph after several separators — the historical "ghost lands four
        // lines below" shape.
        let parent = "first line\nsecond line\nthird line"
        let caret = (parent as NSString).length
        let result = placement(
            runs: ["first line", "second line", "third line"],
            parent: parent,
            caret: caret
        )

        XCTAssertEqual(result, Placement(runIndex: 2, fraction: 1, mode: .aligned))
    }

    func test_placement_midRunCaretProducesProportionalFraction() {
        let result = placement(runs: ["aaaa", "bbbb"], parent: "aaaa\nbbbb", caret: 7)

        XCTAssertEqual(result?.runIndex, 1)
        XCTAssertEqual(result?.fraction ?? -1, 0.5, accuracy: 0.001)
    }

    func test_placement_caretInBlankLineGapSnapsToNearestRenderedEdge() {
        // Caret on a blank line between paragraphs ("aa\n|\nbb"): equidistant from both runs,
        // which snaps to the previous run's trailing edge — at most one line from the truth,
        // which text alone cannot resolve.
        let result = placement(runs: ["aa", "bb"], parent: "aa\n\nbb", caret: 3)

        XCTAssertEqual(result, Placement(runIndex: 0, fraction: 1, mode: .aligned))
    }

    func test_placement_collapsedBlankParentStaysExact() {
        // Hosts that collapse blank lines emit a parent value with single separators; alignment
        // is indifferent to how many visual blanks the separators hide.
        let result = placement(runs: ["aa", "bb"], parent: "aa\nbb", caret: 5)

        XCTAssertEqual(result, Placement(runIndex: 1, fraction: 1, mode: .aligned))
    }

    func test_placement_caretOffsetBeyondParentClampsToEnd() {
        let result = placement(runs: ["aa", "bb"], parent: "aa\nbb", caret: 99)

        XCTAssertEqual(result?.runIndex, 1)
        XCTAssertEqual(result?.fraction, 1)
    }

    // MARK: - Flattened-value hardening

    func test_placement_nonBreakingSpacesMatchPlainSpaces() {
        // Hosts mix NBSP and plain spaces between the parent value and run texts; matching must
        // survive both directions.
        let nbspRun = placement(runs: ["aa", "\u{00A0}bb"], parent: "aa\n bb", caret: 5)
        XCTAssertEqual(nbspRun?.runIndex, 1)
        XCTAssertEqual(nbspRun?.mode, .aligned)

        let nbspParent = placement(runs: ["aa", "bb"], parent: "aa\u{00A0}bb", caret: 3)
        XCTAssertEqual(nbspParent, Placement(runIndex: 1, fraction: 0, mode: .aligned))
    }

    func test_placement_shortRunDoesNotAnchorInsideFusedClump() {
        // Captured Gmail values fuse adjacent blocks with no separator ("i'm"+"hi" → "i'mhi").
        // The boundary rule must reject "hi" inside the clump, and the windowed second pass must
        // then recover both fused runs between the boundary-clean anchors.
        let parent = "i'mhi echo"
        let result = placement(runs: ["i'm", "hi", "echo"], parent: parent, caret: 4)

        XCTAssertEqual(result?.runIndex, 1)
        XCTAssertEqual(result?.fraction ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(result?.mode, .aligned)
    }

    func test_placement_standaloneRunPreferredOverFusedOccurrence() {
        // "hi" occurs fused at the start and standalone later; the anchor must be the standalone
        // occurrence, not the clump.
        let parent = "i'mhi went\nhi"
        let caret = (parent as NSString).length
        let result = placement(runs: ["i'm", "hi went", "hi"], parent: parent, caret: caret)

        XCTAssertEqual(result, Placement(runIndex: 2, fraction: 1, mode: .aligned))
    }

    func test_placement_unanchorableRunIsSkippedAndCaretMapsAgainstTheRest() {
        // One run's text is absent from the parent value entirely; the others still anchor and
        // the caret maps against them (partial alignment), not the legacy walk.
        let result = placement(runs: ["zz", "bb"], parent: "aa\nbb", caret: 4)

        XCTAssertEqual(result?.runIndex, 1)
        XCTAssertEqual(result?.mode, .partiallyAligned)
    }

    func test_placement_nothingAnchorableFallsBackToCumulativeWalk() {
        let result = placement(runs: ["zz", "qq"], parent: "aa\nbb", caret: 1)

        XCTAssertEqual(result, Placement(runIndex: 0, fraction: 0.5, mode: .legacyCumulative))
    }

    func test_placement_emptyRunListReturnsNil() {
        XCTAssertNil(placement(runs: [], parent: "aa", caret: 1))
    }

    // MARK: - Field regression (captured Gmail value, 2026-06-11)

    /// Verbatim shape captured from a real Gmail compose via the llm-io stream: the parent value
    /// flattens visual lines with single spaces (or none), and the run texts are the individual
    /// rendered lines. The caret was at the end, on the last short "hi" line; every earlier
    /// mapping placed it lines away. This is the exact data the alignment must survive.
    func test_placement_capturedGmailFlatValueMapsCaretToItsRealLine() {
        let runs = [
            "hi how's",
            "i want to know if there is a way to get the points i lost it 'secho the quick brown fox is",
            " hi how's it",
            "hi",
            "i wanted to",
            "hi"
        ]
        let parent = "hi how's i want to know if there is a way to get the points i lost it 'secho "
            + "the quick brown fox is hi how's it hi i wanted to hi"
        let caret = (parent as NSString).length

        let atEnd = placement(runs: runs, parent: parent, caret: caret)
        XCTAssertEqual(atEnd, Placement(runIndex: 5, fraction: 1, mode: .aligned))

        // Caret at the end of the long wrapped paragraph ("...brown fox is|"): must stay on that
        // run, not bleed into the " hi how's it" line that follows with no separator but its own
        // leading space.
        let foxLineEnd = (parent as NSString).range(of: "brown fox is").upperBound
        let midDocument = placement(runs: runs, parent: parent, caret: foxLineEnd)
        XCTAssertEqual(midDocument?.runIndex, 1)
        XCTAssertEqual(midDocument?.fraction ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(midDocument?.mode, .aligned)

        // Caret mid-"i wanted to" (the line every stale mapping kept landing on): maps there only
        // when the offset genuinely points there.
        let wantedStart = (parent as NSString).range(of: " i wanted to").location + 1
        let midWanted = placement(runs: runs, parent: parent, caret: wantedStart + 5)
        XCTAssertEqual(midWanted?.runIndex, 4)
        XCTAssertEqual(midWanted?.mode, .aligned)
    }

    // MARK: - Trailing-gap extrapolation (text published before run frames reflow)

    func test_placement_textGrownPastTheLastRunReportsTheTrailingGap() {
        // The accept-time staleness signature: the parent value already contains the inserted
        // " world" but the cached runs predate it. Parking the caret at the stale trailing edge
        // sat a full word left of the truth; the gap count lets the caller extend the estimate by
        // measured character widths instead.
        let result = placement(runs: ["Hello"], parent: "Hello world", caret: 11)

        XCTAssertEqual(
            result,
            Placement(runIndex: 0, fraction: 1, mode: .aligned, trailingGapCharacters: 6)
        )
    }

    func test_placement_interiorGapNearThePreviousEdgeReportsTheGap() {
        // Insert before a later block: the caret sits in the widened separator gap, nearer the
        // run it extends; the gap is extrapolable because it stays on the same line.
        let result = placement(runs: ["Hello", "later block"], parent: "Hello inserted\nlater block", caret: 8)

        XCTAssertEqual(
            result,
            Placement(runIndex: 0, fraction: 1, mode: .aligned, trailingGapCharacters: 3)
        )
    }

    func test_placement_gapSpanningALineBreakKeepsTheSnap() {
        // A newline in the gap means the caret renders on another line entirely; linear
        // extrapolation along X would be wrong, so the trailing-edge snap stays.
        let result = placement(runs: ["Hello"], parent: "Hello\nworld", caret: 11)

        XCTAssertEqual(
            result,
            Placement(runIndex: 0, fraction: 1, mode: .aligned, trailingGapCharacters: 0)
        )
    }

    func test_placement_hugeTrailingGapRefusesExtrapolation() {
        // A reflow-everything edit (large paste) cannot be modeled by a linear extension; fall
        // back to the snap and let the fresh walk correct.
        let pasted = String(repeating: "a", count: 80)
        let result = placement(runs: ["Hello"], parent: "Hello " + pasted, caret: 6 + 80)

        XCTAssertEqual(result?.trailingGapCharacters, 0)
        XCTAssertEqual(result?.fraction ?? -1, 1, accuracy: 0.001)
    }

    func test_placement_caretInsideARunReportsNoGap() {
        let result = placement(runs: ["Hello world"], parent: "Hello world", caret: 5)

        XCTAssertEqual(result?.trailingGapCharacters, 0)
    }
}
