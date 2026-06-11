import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the presentation-time caret layout repair rule: when (and only when) the context's
/// resolver quality is `.estimated`, the overlay anchor is recomputed from the hidden text layout
/// and the geometry quality upgraded to `.layoutEstimated`. Every rejection must keep today's
/// behavior bit-for-bit (the passed rect and `.estimated` survive untouched).
@MainActor
final class SuggestionCaretLayoutRepairTests: XCTestCase {
    /// Deliberately far outside any field frame so a substitution is unmistakable.
    private let fallbackRect = CGRect(x: 999, y: 999, width: 2, height: 18)

    func test_layoutRepair_substitutesEstimateAndUpgradesQualityForEstimatedContext() {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let context = CotabbyTestFixtures.focusedInputContext(
            inputFrameRect: frame,
            caretQuality: .estimated,
            precedingText: "Hello"
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .layoutEstimated)
        XCTAssertNotEqual(anchor.rect, fallbackRect)
        XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(anchor.rect))
        guard case .estimate = anchor.outcome else {
            return XCTFail("Expected an estimate outcome, got \(String(describing: anchor.outcome))")
        }
    }

    func test_layoutRepair_leavesTrustedQualityUntouched() {
        // Exact and derived geometry must never be second-guessed by the repair; it exists solely
        // to rescue the AXFrame fallback.
        let context = CotabbyTestFixtures.focusedInputContext(caretQuality: .exact)

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .exact)
        XCTAssertEqual(anchor.rect, fallbackRect)
        XCTAssertNil(anchor.outcome)
    }

    func test_layoutRepair_keepsEstimatedQualityWhenEstimatorRejects() {
        // Tabs poison the layout (host tab stops are unobservable), so the repair must decline
        // and preserve the existing popup-card path.
        let context = CotabbyTestFixtures.focusedInputContext(
            caretQuality: .estimated,
            precedingText: "column\tvalue"
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .estimated)
        XCTAssertEqual(anchor.rect, fallbackRect)
        XCTAssertEqual(anchor.outcome, .rejected(.containsTab))
    }

    func test_layoutRepair_rejectsPrefixThatFilledTheContextWindow() {
        // A prefix that filled the snapshot's bounded window may not start at the document start,
        // so wrap/Y math would be computed against a mid-document offset.
        let cappedPrefix = String(
            repeating: "a",
            count: FocusSnapshotResolver.focusedTextContextWindowUTF16
        )
        let context = CotabbyTestFixtures.focusedInputContext(
            inputFrameRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            caretQuality: .estimated,
            precedingText: cappedPrefix
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .estimated)
        XCTAssertEqual(anchor.outcome, .rejected(.prefixTruncated))
    }

    func test_layoutRepair_pendingInsertionAdvancesTheEstimate() {
        // The word-accept path passes the not-yet-published insertion so the caret lands after
        // the inserted chunk, not before it.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 24)
        let context = CotabbyTestFixtures.focusedInputContext(
            inputFrameRect: frame,
            caretQuality: .estimated,
            precedingText: "Hello"
        )

        let without = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: "",
            isRightToLeft: false
        )
        let with = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: " world",
            isRightToLeft: false
        )

        XCTAssertEqual(without.quality, .layoutEstimated)
        XCTAssertEqual(with.quality, .layoutEstimated)
        XCTAssertGreaterThan(with.rect.minX, without.rect.minX)
    }
}
