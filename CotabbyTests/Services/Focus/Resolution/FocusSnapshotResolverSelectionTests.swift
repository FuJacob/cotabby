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

    /// A caret at its paragraph's very start shares the paragraph's key: the empty-line miss right
    /// after Return is handled by the outcome's retry rule, not by a separate key (a separate key
    /// let the miss answer again whenever the caret returned to the start).
    func testCaretAtParagraphStartSharesTheParagraphsKey() {
        XCTAssertEqual(paragraphKey(document: "First paragraph.\n", caret: 17), "p17")
        XCTAssertEqual(paragraphKey(document: "First paragraph.\nN", caret: 18), "p17")
        XCTAssertEqual(paragraphKey(document: "", caret: 0), "p0")
    }

    func testParagraphReportsItsStartOffsetOnlyWhenVisible() {
        let visible = String(repeating: "a", count: 6000) + "\n" + String(repeating: "b", count: 3000)
        XCTAssertEqual(paragraph(document: visible, caret: 8000).startOffset, 6001)

        let outOfView = String(repeating: "a", count: 60_000)
        XCTAssertNil(paragraph(document: outOfView, caret: 11 * window).startOffset)
    }

    // MARK: - Line-content-edge re-measure policy

    /// The first visual line of a paragraph starting at offset 17, measured with the caret at 18.
    private let firstLine = CGRect(x: 288, y: 600, width: 400, height: 30)
    private let lineBelow = CGRect(x: 288, y: 570, width: 400, height: 30)

    private func measured(
        isParagraphFirstLine: Bool,
        caretLocation: Int = 18,
        lineRect: CGRect? = nil,
        leftX: CGFloat = 288
    ) -> LineContentEdgesOutcome {
        .measured(
            LineContentEdgesMeasurement(
                edges: .lineQueryMargin(leftX: leftX),
                lineRect: lineRect ?? firstLine,
                isParagraphFirstLine: isParagraphFirstLine,
                caretLocation: caretLocation
            )
        )
    }

    /// A precise caret box on `line`.
    private func caret(_ location: Int, on line: CGRect?) -> FocusSnapshotResolver.LineEdgeCaret {
        FocusSnapshotResolver.LineEdgeCaret(
            location: location,
            preciseRect: line.map { CGRect(x: 300, y: $0.minY, width: 2, height: $0.height) }
        )
    }

    private func needsRemeasure(_ cached: LineContentEdgesOutcome, _ caret: FocusSnapshotResolver.LineEdgeCaret) -> Bool {
        FocusSnapshotResolver.lineContentEdgesNeedRemeasure(cached, caret: caret)
    }

    /// Reproduced in Word: a first-line-indented paragraph measured on its first line kept that
    /// indent for every wrapped line. Once a precise caret sits on another visual line, the
    /// provisional first-line margin must be measured again.
    func testFirstLineMarginIsRemeasuredOnceThePreciseCaretLeavesThatLine() {
        let indentedFirstLine = CGRect(x: 360, y: 600, width: 400, height: 30)
        XCTAssertTrue(needsRemeasure(measured(isParagraphFirstLine: true, lineRect: indentedFirstLine), caret(60, on: lineBelow)))
    }

    func testFirstLineMarginIsKeptWhileTheCaretStaysOnThatLine() {
        XCTAssertFalse(needsRemeasure(measured(isParagraphFirstLine: true), caret(30, on: firstLine)))
    }

    /// Bounds lookups to one per caret move: at a wrap boundary the caret's box and the line the host
    /// reports for its offset can disagree, and re-measuring the same offset would return the same
    /// line on every poll tick.
    func testAnUnmovedCaretNeverRemeasures() {
        XCTAssertFalse(needsRemeasure(measured(isParagraphFirstLine: true, caretLocation: 60), caret(60, on: lineBelow)))
    }

    func testAnEstimatedCaretCannotTriggerARemeasure() {
        XCTAssertFalse(needsRemeasure(measured(isParagraphFirstLine: true), caret(60, on: nil)))
    }

    func testContinuationLineMarginStandsForTheWholeParagraph() {
        XCTAssertFalse(needsRemeasure(measured(isParagraphFirstLine: false, lineRect: lineBelow), caret(400, on: firstLine)))
    }

    /// The empty line right after Return is the one failure that fixes itself: once the caret moves
    /// (the first character is typed) the lookup must run again.
    func testEmptyLineMissIsRetriedOnceTheCaretMoves() {
        XCTAssertTrue(needsRemeasure(.emptyLine(caretLocation: 17), caret(18, on: firstLine)))
    }

    /// While the user pauses on the empty line every poll tick sees the same caret; retrying then
    /// would put AX calls on the idle poll.
    func testEmptyLineMissIsNotRetriedWhileTheCaretStays() {
        XCTAssertFalse(needsRemeasure(.emptyLine(caretLocation: 17), caret(17, on: firstLine)))
    }

    func testUnavailableIsNeverRetried() {
        XCTAssertFalse(needsRemeasure(.unavailable, caret(400, on: lineBelow)))
    }

    // MARK: - Line-content-edge cache flow

    /// Found in review: press Return, type into the new paragraph, then move back to its start. The miss recorded while the line was empty must not answer again — the measurement
    /// taken after typing replaced it, and it is what the caret at the start gets, without a lookup.
    @MainActor
    func testReturningToAParagraphStartUsesTheMeasurementNotTheEarlierEmptyLineMiss() {
        let cache = FocusSessionScopedCache<LineContentEdgesOutcome>()
        var lookups = 0
        func edges(caretAt location: Int, lookup outcome: LineContentEdgesOutcome) -> ObservedContentEdges? {
            FocusSnapshotResolver.cachedLineContentEdges(
                in: cache,
                key: "lineEdges:field:p17",
                focusChangeSequence: 1,
                caret: caret(location, on: firstLine)
            ) {
                lookups += 1
                return outcome
            }
        }

        XCTAssertNil(edges(caretAt: 17, lookup: .emptyLine(caretLocation: 17)), "right after Return")
        XCTAssertEqual(edges(caretAt: 18, lookup: measured(isParagraphFirstLine: true))?.leftX, 288, "first character typed")
        XCTAssertEqual(edges(caretAt: 17, lookup: .unavailable)?.leftX, 288, "back at the paragraph start")
        XCTAssertEqual(lookups, 2, "returning to the start must be answered from the cache")
    }

    @MainActor
    func testAnEmptyLineMissCostsNothingWhileTheCaretStaysPut() {
        let cache = FocusSessionScopedCache<LineContentEdgesOutcome>()
        var lookups = 0
        for _ in 0..<5 {
            _ = FocusSnapshotResolver.cachedLineContentEdges(
                in: cache,
                key: "lineEdges:field:p17",
                focusChangeSequence: 1,
                caret: caret(17, on: firstLine)
            ) {
                lookups += 1
                return .emptyLine(caretLocation: 17)
            }
        }
        XCTAssertEqual(lookups, 1)
    }
}
