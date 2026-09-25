import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests the pure caret-geometry trust policy used by `FocusSnapshotResolver`.
///
/// These tests intentionally avoid live Accessibility objects. The regression we are guarding
/// against is not whether AX can produce a rect; it is whether Cotabby trusts a descendant rect over
/// the focused input's own usable rect.
final class FocusSnapshotResolverSelectionTests: XCTestCase {
    private let primaryRect = CGRect(x: 10, y: 20, width: 2, height: 16)
    private let deepRect = CGRect(x: 100, y: 120, width: 2, height: 16)

    func testShouldSearchDeepOnlyForWeakPrimaryGeometry() {
        XCTAssertFalse(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .exact
        ))
        XCTAssertFalse(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .derived
        ))
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .estimated
        ))
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: nil
        ))
        XCTAssertTrue(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: nil,
            primaryQuality: .derived
        ))
    }

    func testShouldNotRepeatDeepSearchAfterWrappedRunWasDemoted() {
        XCTAssertFalse(CaretGeometrySelector.shouldSearchDeep(
            primaryRect: primaryRect,
            primaryQuality: .estimated,
            primaryAllowsDeepSearch: false
        ))
    }

    func testPrimaryExactWinsOverDeepExact() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .exact,
            primaryObservedCharWidth: 7,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 4)
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .exact)
        XCTAssertEqual(selected.source, "exact primary")
        XCTAssertEqual(selected.observedCharWidth, 7)
    }

    func testPrimaryDerivedWinsOverDeepExact() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .derived,
            primaryObservedCharWidth: 8,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 3)
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .derived)
        XCTAssertEqual(selected.source, "derived primary")
        XCTAssertEqual(selected.observedCharWidth, 8)
    }

    func testDeepExactWinsWhenPrimaryIsOnlyEstimated() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .estimated,
            primaryObservedCharWidth: nil,
            deepResult: CaretGeometryResult(rect: deepRect, quality: .exact, observedCharWidth: 5)
        ))

        XCTAssertEqual(selected.rect, deepRect)
        XCTAssertEqual(selected.quality, .exact)
        XCTAssertEqual(selected.source, "exact deep")
        XCTAssertEqual(selected.observedCharWidth, 5)
    }

    func testPrimaryFallbackStillWorksWithoutDeepGeometry() throws {
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .estimated,
            primaryObservedCharWidth: nil,
            deepResult: nil
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .estimated)
        XCTAssertEqual(selected.source, "estimated primary-fallback")
    }

    func testSelectReturnsNilWhenNeitherSourceProducedARect() {
        XCTAssertNil(CaretGeometrySelector.select(
            primaryRect: nil,
            primaryQuality: nil,
            primaryObservedCharWidth: nil,
            deepResult: nil
        ))
    }

    func testPrimarySourceDetailIsAppendedToTheSourceLabel() throws {
        // The resolver-supplied mapping detail must surface in the debug badge label so logs show
        // not just which branch won but how the caret mapped.
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: .exact,
            primaryObservedCharWidth: nil,
            primarySourceDetail: "marker-run",
            deepResult: nil
        ))

        XCTAssertEqual(selected.source, "exact primary (marker-run)")
        XCTAssertEqual(selected.quality, .exact)
    }

    func testUnknownPrimaryQualityFallsBackToEstimatedWithUnknownLabel() throws {
        // A rect with no quality signal at all still ships (better than nothing), but it must be
        // labeled "unknown" and demoted to `.estimated` so downstream policy treats it as weak.
        let selected = try XCTUnwrap(CaretGeometrySelector.select(
            primaryRect: primaryRect,
            primaryQuality: nil,
            primaryObservedCharWidth: nil,
            deepResult: nil
        ))

        XCTAssertEqual(selected.rect, primaryRect)
        XCTAssertEqual(selected.quality, .estimated)
        XCTAssertEqual(selected.source, "unknown primary-fallback")
    }

    // MARK: - Line-content-edge paragraph key

    /// Builds the paragraph from the same before-caret window `nativeTextWindow` produces: at most
    /// `focusedTextContextWindowUTF16` units ending at the caret. Text after the caret never affects
    /// the result, so it is omitted.
    private func paragraph(document: String, caret: Int) -> FocusSnapshotResolver.LineEdgeParagraph {
        let doc = document as NSString
        let before = min(caret, FocusSnapshotResolver.focusedTextContextWindowUTF16)
        let window = doc.substring(with: NSRange(location: caret - before, length: before))
        return FocusSnapshotResolver.lineContentEdgesParagraph(
            windowText: window,
            windowCaretLocation: before,
            documentCaretLocation: caret
        )
    }

    private func paragraphKey(document: String, caret: Int) -> String {
        paragraph(document: document, caret: caret).key
    }

    private let window = FocusSnapshotResolver.focusedTextContextWindowUTF16

    func testParagraphKeyUsesVisibleParagraphStartInDocumentCoordinates() {
        // The window [3904, 8000) contains the newline at 6000, so the paragraph starts at 6001 in
        // document coordinates even though the window itself starts at 3904.
        let document = String(repeating: "a", count: 6000) + "\n" + String(repeating: "b", count: 3000)
        XCTAssertEqual(paragraphKey(document: document, caret: 8000), "p6001")
    }

    func testParagraphKeyStaysStableWhileTypingWithAVisibleParagraphStart() {
        // The window slides with the caret, but origin + position-in-window stays constant.
        let document = String(repeating: "a", count: 6000) + "\n" + String(repeating: "b", count: 3000)
        let keys = Set((7000..<7300).map { paragraphKey(document: document, caret: $0) })
        XCTAssertEqual(keys, ["p6001"])
    }

    func testParagraphKeyIsZeroWhenTheWindowStartsAtTheDocumentStart() {
        XCTAssertEqual(paragraphKey(document: "hello world", caret: 11), "p0")
    }

    /// The regression this key exists to prevent. With the paragraph start out of view, the previous
    /// rule keyed on the window's document origin, which advances with every character typed: 1,000
    /// keystrokes produced 1,000 distinct keys, and every one missed the cache and issued three
    /// blocking AX calls on the typing path. Bucketing the origin keeps the key fixed.
    func testParagraphKeyStaysStableWhileTypingThroughAParagraphLongerThanTheWindow() {
        let document = String(repeating: "a", count: 60_000)
        let start = 11 * window
        let keys = Set((start..<(start + 1000)).map { paragraphKey(document: document, caret: $0) })

        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys.first?.hasPrefix("u") == true)
    }

    func testParagraphKeyChangesAtMostOncePerWindowOfTyping() {
        let document = String(repeating: "a", count: 60_000)
        // Origins 11*window - 1 and 11*window straddle a bucket boundary...
        XCTAssertNotEqual(
            paragraphKey(document: document, caret: 12 * window - 1),
            paragraphKey(document: document, caret: 12 * window)
        )
        // ...and then the key holds for a full window of typing.
        XCTAssertEqual(
            paragraphKey(document: document, caret: 12 * window),
            paragraphKey(document: document, caret: 13 * window - 1)
        )
    }

    func testParagraphKeyNeverMergesTwoParagraphsLongerThanTheWindow() {
        // Both carets have their paragraph start out of view. The second caret sits more than one
        // window past its paragraph's start, which lies past the first caret, so the two window
        // origins differ by more than a bucket and the keys cannot coincide.
        let document = String(repeating: "a", count: 30_000) + "\n" + String(repeating: "b", count: 30_000)
        let endOfFirst = paragraphKey(document: document, caret: 30_000)
        let justPastViewInSecond = paragraphKey(document: document, caret: 30_001 + window + 1)

        XCTAssertTrue(endOfFirst.hasPrefix("u"))
        XCTAssertTrue(justPastViewInSecond.hasPrefix("u"))
        XCTAssertNotEqual(endOfFirst, justPastViewInSecond)
    }

    /// Right after Return the caret's line is empty, so the host has no line box to measure and the
    /// lookup fails. That miss must not be cached under the key the paragraph keeps once text is
    /// typed, or every paragraph started with Return keeps the page-edge fallback (reproduced in
    /// Word). The caret at the paragraph's start therefore gets its own key.
    func testCaretAtParagraphStartIsKeyedApartFromTheTypedParagraph() {
        let emptyNewParagraph = "First paragraph.\n"
        let afterFirstCharacter = "First paragraph.\nN"

        XCTAssertEqual(paragraphKey(document: emptyNewParagraph, caret: 17), "p17@start")
        XCTAssertEqual(paragraphKey(document: afterFirstCharacter, caret: 18), "p17")
    }

    func testCaretAtDocumentStartIsKeyedAsAParagraphStart() {
        XCTAssertEqual(paragraphKey(document: "", caret: 0), "p0@start")
        XCTAssertEqual(paragraphKey(document: "H", caret: 1), "p0")
    }

    func testParagraphReportsItsStartOffsetOnlyWhenVisible() {
        let visible = String(repeating: "a", count: 6000) + "\n" + String(repeating: "b", count: 3000)
        XCTAssertEqual(paragraph(document: visible, caret: 8000).startOffset, 6001)

        let outOfView = String(repeating: "a", count: 60_000)
        XCTAssertNil(paragraph(document: outOfView, caret: 11 * window).startOffset)
    }

    // MARK: - Line-content-edge re-measure policy

    private func measurement(
        isParagraphFirstLine: Bool,
        caretLocation: Int = 100,
        lineRect: CGRect = CGRect(x: 360, y: 600, width: 400, height: 30)
    ) -> LineContentEdgesMeasurement {
        LineContentEdgesMeasurement(
            edges: .lineQueryMargin(leftX: lineRect.minX),
            lineRect: lineRect,
            isParagraphFirstLine: isParagraphFirstLine,
            caretLocation: caretLocation
        )
    }

    /// Reproduced in Word: a first-line-indented paragraph measured on its first line kept that
    /// indent for every wrapped line. Once a precise caret sits on another visual line, the
    /// provisional first-line margin must be measured again.
    func testFirstLineMarginIsRemeasuredOnceThePreciseCaretLeavesThatLine() {
        let lineBelow = CGRect(x: 290, y: 564, width: 2, height: 30)
        XCTAssertTrue(
            FocusSnapshotResolver.lineContentEdgesNeedRemeasure(
                measurement(isParagraphFirstLine: true),
                caretLocation: 140,
                caretRect: lineBelow
            )
        )
    }

    func testFirstLineMarginIsKeptWhileTheCaretStaysOnThatLine() {
        let sameLine = CGRect(x: 700, y: 600, width: 2, height: 30)
        XCTAssertFalse(
            FocusSnapshotResolver.lineContentEdgesNeedRemeasure(
                measurement(isParagraphFirstLine: true),
                caretLocation: 110,
                caretRect: sameLine
            )
        )
    }

    /// Bounds lookups to one per caret move: at a wrap boundary the caret's box and the line the host
    /// reports for its offset can disagree, and re-measuring the same offset would return the same
    /// line on every poll tick.
    func testAnUnmovedCaretNeverRemeasures() {
        let lineBelow = CGRect(x: 290, y: 564, width: 2, height: 30)
        XCTAssertFalse(
            FocusSnapshotResolver.lineContentEdgesNeedRemeasure(
                measurement(isParagraphFirstLine: true, caretLocation: 140),
                caretLocation: 140,
                caretRect: lineBelow
            )
        )
    }

    func testAnEstimatedCaretCannotTriggerARemeasure() {
        // The caller passes nil for any caret that is not a precise measurement.
        XCTAssertFalse(
            FocusSnapshotResolver.lineContentEdgesNeedRemeasure(
                measurement(isParagraphFirstLine: true),
                caretLocation: 140,
                caretRect: nil
            )
        )
    }

    func testContinuationLineMarginStandsForTheWholeParagraph() {
        let farAway = CGRect(x: 290, y: 200, width: 2, height: 30)
        XCTAssertFalse(
            FocusSnapshotResolver.lineContentEdgesNeedRemeasure(
                measurement(isParagraphFirstLine: false),
                caretLocation: 400,
                caretRect: farAway
            )
        )
    }

    func testCachedFailureIsNotRetried() {
        // Retrying failures would issue AX calls on every poll tick; the empty-paragraph failure,
        // the one that fixes itself, re-keys instead.
        XCTAssertFalse(
            FocusSnapshotResolver.lineContentEdgesNeedRemeasure(
                nil,
                caretLocation: 140,
                caretRect: CGRect(x: 290, y: 564, width: 2, height: 30)
            )
        )
    }
}
