import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the presentation-time caret layout repair rule: when (and only when) the context's
/// resolver quality is `.estimated`, the overlay anchor is recomputed from the hidden text layout
/// and the geometry quality upgraded to `.layoutEstimated`. Every rejection must keep today's
/// behavior bit-for-bit (the passed rect and `.estimated` survive untouched).
///
/// For `.derived` geometry the rule is additionally scoped by provenance: only web-content hosts
/// (whose AX caret bounds have known wrong-line pathologies) expose their derived rects to the
/// estimate's line-mismatch override. Native hosts' derived rects are AX ground truth and bypass
/// the estimator entirely; the `.estimated` substitution stays provenance-independent because
/// there is no real measurement to protect.
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

    // MARK: - Derived geometry (web hosts: line-mismatch gate)

    func test_layoutRepair_derivedAgreementKeepsAXRect() {
        // The estimate and the AX rect land on the same line: AX wins, because its X carries the
        // host's real glyph positions. Well-behaved derived hosts must never regress.
        let frame = CGRect(x: 0, y: 0, width: 300, height: 32)
        let axRect = CGRect(x: 50, y: 8, width: 2, height: 16)
        let context = CotabbyTestFixtures.focusedInputContext(
            caretRect: axRect,
            inputFrameRect: frame,
            caretQuality: .derived,
            precedingText: "Hello",
            isWebContentField: true
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: axRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .derived)
        XCTAssertEqual(anchor.rect, axRect)
        guard case .estimate = anchor.outcome else {
            return XCTFail("Expected an estimate outcome, got \(String(describing: anchor.outcome))")
        }
    }

    func test_layoutRepair_derivedLineMismatchSubstitutesEstimateForWebContent() {
        // The AX rect sits three line boxes below where the text layout puts the caret — the
        // Gmail-class blank-line drift this gate exists for. Web content only: the host's AX
        // bridge, not its layout, is the suspect there.
        let frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let axRect = CGRect(x: 50, y: 52, width: 2, height: 16)
        let context = CotabbyTestFixtures.focusedInputContext(
            caretRect: axRect,
            inputFrameRect: frame,
            caretQuality: .derived,
            precedingText: "Hello",
            isWebContentField: true
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: axRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .layoutEstimated)
        XCTAssertNotEqual(anchor.rect, axRect)
        // Top-aligned first line: the substituted caret hangs from the field's top inset, using
        // the AX rect's height as the observed line box.
        XCTAssertEqual(anchor.rect.maxY, frame.maxY - 4, accuracy: 0.6)
        XCTAssertEqual(anchor.rect.height, axRect.height, accuracy: 0.01)
    }

    // MARK: - Derived geometry (native hosts: AX is ground truth)

    func test_layoutRepair_nativeDerivedLineMismatchKeepsAXRect() {
        // Identical geometry to the web mismatch test, but the field is native. Native rich-text
        // views render what a uniform hidden layout cannot model (Apple Notes draws a 23pt title
        // line above 16pt body lines, plus paragraph spacing), so a vertical disagreement there
        // means the estimate is wrong while the AX prev-character bounds are exactly right.
        // Substituting here was the post-#670 Notes regression: ghost text drifted off the real
        // caret line. The estimator must not even run (nil outcome): it would burn a TextKit
        // layout inside the accept keystroke's handling window to compute nothing actionable.
        let frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let axRect = CGRect(x: 50, y: 52, width: 2, height: 16)
        let context = CotabbyTestFixtures.focusedInputContext(
            caretRect: axRect,
            inputFrameRect: frame,
            caretQuality: .derived,
            precedingText: "Hello",
            isWebContentField: false
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: axRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .derived)
        XCTAssertEqual(anchor.rect, axRect)
        XCTAssertNil(anchor.outcome)
        XCTAssertEqual(anchor.skipReason, .nativeHostGeometry)
    }

    func test_layoutRepair_nativeEstimatedStillSubstitutes() {
        // `.estimated` means AX offered no real caret position at all (only the field frame), so
        // there is no native measurement for the trust policy to protect: the layout estimate
        // applies regardless of provenance.
        let frame = CGRect(x: 0, y: 0, width: 240, height: 32)
        let context = CotabbyTestFixtures.focusedInputContext(
            inputFrameRect: frame,
            caretQuality: .estimated,
            precedingText: "Hello",
            isWebContentField: false
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: fallbackRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .layoutEstimated)
        XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(anchor.rect))
    }

    func test_layoutRepair_runMeasuredDerivedKeepsAXEvenOnLineMismatch() {
        // Same wrong-looking vertical gap as the mismatch test, but this rect came from measured
        // child-run frames (content edges present). Run frames carry the host's real line
        // positions — including blank lines Gmail collapses out of the AX text — so the
        // blank-blind layout estimate must never override them. The estimator is skipped outright
        // (nil outcome): this path runs inside the accept keystroke's handling window, where
        // layout work on a large flat prefix is pure risk during a rapid Tab burst.
        let frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let axRect = CGRect(x: 50, y: 52, width: 2, height: 16)
        let context = CotabbyTestFixtures.focusedInputContext(
            caretRect: axRect,
            inputFrameRect: frame,
            caretQuality: .derived,
            observedContentEdges: ObservedContentEdges(leftX: 4, topY: 116),
            precedingText: "Hello",
            isWebContentField: true
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: axRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .derived)
        XCTAssertEqual(anchor.rect, axRect)
        XCTAssertNil(anchor.outcome)
        XCTAssertEqual(anchor.skipReason, .runMeasuredGeometry)
    }

    func test_layoutRepair_derivedKeepsAXRectWhenEstimatorRejects() {
        let axRect = CGRect(x: 50, y: 8, width: 2, height: 16)
        let context = CotabbyTestFixtures.focusedInputContext(
            caretRect: axRect,
            caretQuality: .derived,
            precedingText: "column\tvalue",
            isWebContentField: true
        )

        let anchor = SuggestionCoordinator.layoutRepairedAnchor(
            for: context,
            fallbackRect: axRect,
            pendingInsertion: "",
            isRightToLeft: false
        )

        XCTAssertEqual(anchor.quality, .derived)
        XCTAssertEqual(anchor.rect, axRect)
        XCTAssertEqual(anchor.outcome, .rejected(.containsTab))
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
