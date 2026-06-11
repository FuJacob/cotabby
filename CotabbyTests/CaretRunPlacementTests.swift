import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the caret-to-text-run mapping used by the child-run geometry path (Gmail/Outlook-class
/// editors). The mapping must be alignment-based: Chromium parent values separate blocks with
/// newlines (and collapse blank lines) that the run texts do not contain, so cumulative-length
/// math drifts the caret into the wrong run — one visual line per unaccounted character.
@MainActor
final class CaretRunPlacementTests: XCTestCase {
    private func placement(
        runs: [String],
        parent: String,
        caret: Int
    ) -> AXTextGeometryResolver.CaretRunPlacement? {
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

        XCTAssertEqual(
            result,
            AXTextGeometryResolver.CaretRunPlacement(runIndex: 1, fraction: 0, usedTextAlignment: true)
        )
    }

    func test_placement_multipleParagraphSeparatorsStayExact() {
        // End of the last paragraph after several separators — the historical "ghost lands four
        // lines below" shape.
        let parent = "first line\nsecond line\nthird line"
        let caret = (parent as NSString).length
        let result = placement(runs: ["first line", "second line", "third line"], parent: parent, caret: caret)

        XCTAssertEqual(
            result,
            AXTextGeometryResolver.CaretRunPlacement(runIndex: 2, fraction: 1, usedTextAlignment: true)
        )
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

        XCTAssertEqual(
            result,
            AXTextGeometryResolver.CaretRunPlacement(runIndex: 0, fraction: 1, usedTextAlignment: true)
        )
    }

    func test_placement_collapsedBlankParentStaysExact() {
        // Hosts that collapse blank lines emit a parent value with single separators; alignment
        // is indifferent to how many visual blanks the separators hide.
        let result = placement(runs: ["aa", "bb"], parent: "aa\nbb", caret: 5)

        XCTAssertEqual(
            result,
            AXTextGeometryResolver.CaretRunPlacement(runIndex: 1, fraction: 1, usedTextAlignment: true)
        )
    }

    func test_placement_caretOffsetBeyondParentClampsToEnd() {
        let result = placement(runs: ["aa", "bb"], parent: "aa\nbb", caret: 99)

        XCTAssertEqual(result?.runIndex, 1)
        XCTAssertEqual(result?.fraction, 1)
    }

    func test_placement_unalignableRunsFallBackToCumulativeWalk() {
        // A run text missing from the parent value (whitespace rewriting, exotic trees) falls
        // back to the legacy cumulative mapping rather than guessing an alignment.
        let result = placement(runs: ["zz", "bb"], parent: "aa\nbb", caret: 1)

        XCTAssertEqual(
            result,
            AXTextGeometryResolver.CaretRunPlacement(runIndex: 0, fraction: 0.5, usedTextAlignment: false)
        )
    }

    func test_placement_emptyRunListReturnsNil() {
        XCTAssertNil(placement(runs: [], parent: "aa", caret: 1))
    }
}
