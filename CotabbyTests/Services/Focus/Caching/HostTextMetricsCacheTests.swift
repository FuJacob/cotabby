import XCTest
@testable import Cotabby

@MainActor
final class HostTextMetricsCacheTests: XCTestCase {
    func testEmptyAnswersAreRetriedSpacedOutThenGivenUp() {
        let cache = HostTextMetricsCache()
        var measurements = 0
        let start = Date()
        for attempt in 0..<(HostTextMetricsCache.maximumAttempts + 3) {
            let now = start.addingTimeInterval(Double(attempt) * HostTextMetricsCache.retryInterval)
            _ = cache.metrics(forKey: "field", caretLocation: 10, now: now) {
                measurements += 1
                return nil
            }
        }
        XCTAssertEqual(measurements, HostTextMetricsCache.maximumAttempts)
    }

    func testCallsInsideTheRetryIntervalDoNotMeasureAgain() {
        let cache = HostTextMetricsCache()
        var measurements = 0
        let start = Date()
        _ = cache.metrics(forKey: "field", caretLocation: 10, now: start) { measurements += 1; return nil }
        _ = cache.metrics(forKey: "field", caretLocation: 10, now: start.addingTimeInterval(0.05)) { measurements += 1; return nil }
        XCTAssertEqual(measurements, 1)
    }

    func testSuccessfulAnswerIsCachedAndKeyChangeResets() {
        let cache = HostTextMetricsCache()
        var measurements = 0
        let metrics = HostTextMetrics(sampleText: "abc", sampleWidth: 30)
        let first = cache.metrics(forKey: "a", caretLocation: 10) { measurements += 1; return metrics }
        let second = cache.metrics(forKey: "a", caretLocation: 10) { measurements += 1; return nil }
        XCTAssertEqual(first, metrics)
        XCTAssertEqual(second, metrics)
        XCTAssertEqual(measurements, 1)
        _ = cache.metrics(forKey: "b", caretLocation: 10) { measurements += 1; return nil }
        XCTAssertEqual(measurements, 2)
    }

    func testMissingSampleIsRemeasuredOnceTheCaretMovesToAMeasurablePrefix() {
        let cache = HostTextMetricsCache()
        let start = Date()
        var measurements = 0
        let lineOnly = HostTextMetrics(lineRect: CGRect(x: 205, y: 300, width: 362, height: 16))
        let withSample = HostTextMetrics(
            sampleText: "The quick", sampleWidth: 75.9, lineRect: lineOnly.lineRect, linePitch: nil
        )
        // Field focused while it held one character: line geometry only.
        let first = cache.metrics(forKey: "f", caretLocation: 1, now: start) { measurements += 1; return lineOnly }
        // Same caret: nothing new to measure.
        let same = cache.metrics(forKey: "f", caretLocation: 1, now: start.addingTimeInterval(1)) {
            measurements += 1
            return withSample
        }
        // The user typed: the sample is re-measured once the caret can carry one.
        let grown = cache.metrics(forKey: "f", caretLocation: 9, now: start.addingTimeInterval(2)) {
            measurements += 1
            return withSample
        }
        let settled = cache.metrics(forKey: "f", caretLocation: 12, now: start.addingTimeInterval(3)) {
            measurements += 1
            return nil
        }
        XCTAssertEqual(first, lineOnly)
        XCTAssertEqual(same, lineOnly)
        XCTAssertEqual(grown, withSample)
        XCTAssertEqual(settled, withSample)
        XCTAssertEqual(measurements, 2)
    }

    func testASampleReMeasureWithoutLineGeometryKeepsTheKnownLineBox() {
        // Safari: the line box is known from focus time (caret 0); at the end of the text the host
        // answers the width sample but no line, and the line box must survive the merge.
        let cache = HostTextMetricsCache()
        let start = Date()
        let lineOnly = HostTextMetrics(lineRect: CGRect(x: 265, y: 534, width: 205, height: 18), linePitch: 22)
        let sampleOnly = HostTextMetrics(sampleText: "Field two alpha bravo charlie", sampleWidth: 204)
        _ = cache.metrics(forKey: "f", caretLocation: 0, now: start) { lineOnly }
        let merged = cache.metrics(forKey: "f", caretLocation: 30, now: start.addingTimeInterval(1)) { sampleOnly }
        XCTAssertEqual(merged?.sampleText, "Field two alpha bravo charlie")
        XCTAssertEqual(merged?.lineRect, lineOnly.lineRect)
        XCTAssertEqual(merged?.linePitch, 22)
    }

    func testMissingSampleRetriesAreBoundedAndKeepTheLineGeometry() {
        let cache = HostTextMetricsCache()
        let start = Date()
        var measurements = 0
        let lineOnly = HostTextMetrics(lineRect: CGRect(x: 0, y: 0, width: 100, height: 16))
        _ = cache.metrics(forKey: "f", caretLocation: 0, now: start) { measurements += 1; return lineOnly }
        for step in 1...(HostTextMetricsCache.maximumSampleAttempts + 4) {
            let result = cache.metrics(forKey: "f", caretLocation: step + 2, now: start.addingTimeInterval(Double(step))) {
                measurements += 1
                return lineOnly
            }
            XCTAssertEqual(result, lineOnly)
        }
        XCTAssertEqual(measurements, 1 + HostTextMetricsCache.maximumSampleAttempts)
    }

    func testMissingPitchIsRemeasuredOnceTheCaretHasTravelledALine() {
        // Chrome textarea: the field is focused on its first line (no line above, nothing below),
        // so the pitch is unknown; once the caret is 16+ units on, the text may have wrapped.
        let cache = HostTextMetricsCache()
        var measures = 0
        let start = Date()
        let first = cache.metrics(forKey: "f", caretLocation: 5, now: start, measure: {
            measures += 1
            return HostTextMetrics(
                sampleText: "hello", sampleWidth: 40, lineRect: CGRect(x: 0, y: 0, width: 300, height: 15), linePitch: nil
            )
        })
        XCTAssertNil(first?.linePitch)
        _ = cache.metrics(forKey: "f", caretLocation: 12, now: start.addingTimeInterval(1), measure: { measures += 1; return nil })
        XCTAssertEqual(measures, 1, "seven units of travel cannot have wrapped")
        let second = cache.metrics(forKey: "f", caretLocation: 40, now: start.addingTimeInterval(2), measure: {
            measures += 1
            return HostTextMetrics(sampleText: nil, sampleWidth: nil, lineRect: nil, linePitch: 15.2)
        })
        XCTAssertEqual(measures, 2)
        XCTAssertEqual(second?.linePitch, 15.2)
        XCTAssertEqual(second?.sampleText, "hello", "a pitch-only answer keeps the known sample")
        XCTAssertEqual(second?.lineRect?.width, 300, "and the known line box")
        let third = cache.metrics(forKey: "f", caretLocation: 80, now: start.addingTimeInterval(3), measure: { measures += 1; return nil })
        XCTAssertEqual(measures, 2, "a known pitch is not measured again")
        XCTAssertEqual(third?.linePitch, 15.2)
    }

    /// A paragraph's box stands in for the pitch until two lines give one: the search goes on, and a
    /// pitch measured between lines replaces it. Measured 2026-09-11 at 110%: the box read 24 for a
    /// 23.1pt line, two lines 23.5.
    func testAParagraphBoxPitchKeepsThePitchSearchGoingUntilTwoLinesGiveOne() {
        let cache = HostTextMetricsCache()
        var measures = 0
        let start = Date()
        let first = cache.metrics(forKey: "f", caretLocation: 5, now: start, measure: {
            measures += 1
            // A sample is known, so the only retry left in play is the pitch's.
            return HostTextMetrics(
                sampleText: "hello", sampleWidth: 40, lineRect: CGRect(x: 113, y: 700, width: 60, height: 17),
                linePitch: 24, linePitchIsFromParagraphBox: true
            )
        })
        XCTAssertEqual(first?.linePitch, 24)
        let second = cache.metrics(forKey: "f", caretLocation: 40, now: start.addingTimeInterval(1), measure: {
            measures += 1
            return HostTextMetrics(linePitch: 23.5, lineRectIsFromTextMarkers: true)
        })
        XCTAssertEqual(measures, 2, "a box pitch does not end the search")
        XCTAssertEqual(second?.linePitch, 23.5)
        XCTAssertEqual(second?.linePitchIsFromParagraphBox, false)
        _ = cache.metrics(forKey: "f", caretLocation: 80, now: start.addingTimeInterval(2), measure: { measures += 1; return nil })
        XCTAssertEqual(measures, 2, "a pitch measured between lines does")
    }

    /// Back on a paragraph's first line the probe can read the box again; the pitch two lines gave
    /// is kept.
    func testAPitchMeasuredBetweenLinesIsNotGivenUpForAParagraphBox() {
        let cache = HostTextMetricsCache()
        let start = Date()
        _ = cache.metrics(forKey: "f", caretLocation: 5, now: start, measure: {
            HostTextMetrics(sampleText: "he", sampleWidth: 14, linePitch: nil)
        })
        let measured = cache.metrics(forKey: "f", caretLocation: 40, now: start.addingTimeInterval(1), measure: {
            HostTextMetrics(linePitch: 23.5)
        })
        XCTAssertEqual(measured?.linePitch, 23.5)
        // A sample-less field keeps asking for a sample; that re-measure returns the box.
        let cacheWithoutSample = HostTextMetricsCache()
        _ = cacheWithoutSample.metrics(forKey: "g", caretLocation: 0, now: start, measure: { HostTextMetrics(linePitch: 23.5) })
        let later = cacheWithoutSample.metrics(forKey: "g", caretLocation: 12, now: start.addingTimeInterval(1), measure: {
            HostTextMetrics(sampleText: "hello there", sampleWidth: 80, linePitch: 24, linePitchIsFromParagraphBox: true)
        })
        XCTAssertEqual(later?.sampleText, "hello there")
        XCTAssertEqual(later?.linePitch, 23.5)
        XCTAssertEqual(later?.linePitchIsFromParagraphBox, false)
    }

    func testMissingPitchRetriesAreBounded() {
        let cache = HostTextMetricsCache()
        var measures = 0
        let start = Date()
        _ = cache.metrics(forKey: "f", caretLocation: 0, now: start, measure: {
            measures += 1
            return HostTextMetrics(sampleText: "ab", sampleWidth: 10, lineRect: nil, linePitch: nil)
        })
        for step in 1...20 {
            let later = start.addingTimeInterval(Double(step))
            _ = cache.metrics(forKey: "f", caretLocation: step * 20, now: later, measure: { measures += 1; return nil })
        }
        XCTAssertEqual(measures, 1 + HostTextMetricsCache.maximumPitchAttempts)
    }

    func testFieldStyleCacheRetriesEmptyStyleUntilTheHostAnswers() {
        let cache = FieldStyleCache()
        let start = Date()
        var attempts = 0
        let style = ResolvedFieldStyle(fontName: nil, fontPointSize: 13, colorHex: nil)
        let first = cache.style(forKey: "f", caretLocation: 5, caretHeight: 17, now: start, styleRun: { nil }) {
            attempts += 1
            return nil
        }
        let second = cache.style(forKey: "f", caretLocation: 6, caretHeight: 17, now: start.addingTimeInterval(1), styleRun: { nil }) {
            attempts += 1
            return style
        }
        let third = cache.style(forKey: "f", caretLocation: 7, caretHeight: 17, now: start.addingTimeInterval(2), styleRun: { nil }) {
            attempts += 1
            return nil
        }
        XCTAssertNil(first)
        XCTAssertEqual(second, style)
        XCTAssertEqual(third, style)
        XCTAssertEqual(attempts, 2)
    }

    func testFieldStyleCacheReusesTheStyleWhileTheCaretStaysInsideTheRunWithoutRunLookups() {
        let cache = FieldStyleCache()
        var runLookups = 0
        var resolves = 0
        let menlo = ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 14, colorHex: nil)
        let run = NSRange(location: 0, length: 18)
        let first = cache.style(forKey: "f", caretLocation: 10, caretHeight: 16, styleRun: { runLookups += 1; return run }) {
            resolves += 1
            return menlo
        }
        let second = cache.style(forKey: "f", caretLocation: 15, caretHeight: 16, styleRun: { runLookups += 1; return run }) {
            resolves += 1
            return menlo
        }
        XCTAssertEqual(first, menlo)
        XCTAssertEqual(second, menlo)
        XCTAssertEqual(runLookups, 1)
        XCTAssertEqual(resolves, 1)
    }

    func testFieldStyleCacheReResolvesWhenTheCaretEntersAnotherRun() {
        let cache = FieldStyleCache()
        let menlo = ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 14, colorHex: nil)
        let helvetica = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
        let menloRun = NSRange(location: 0, length: 18)
        let helveticaRun = NSRange(location: 18, length: 7)
        _ = cache.style(forKey: "f", caretLocation: 18, caretHeight: 16, styleRun: { menloRun }) { menlo }
        let afterTyping = cache.style(forKey: "f", caretLocation: 19, caretHeight: 16, styleRun: { helveticaRun }) { helvetica }
        XCTAssertEqual(afterTyping, helvetica)
    }

    func testFieldStyleCacheReResolvesWhenTheCaretHeightChanges() {
        let cache = FieldStyleCache()
        let small = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 12, colorHex: nil)
        let large = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 24, colorHex: nil)
        _ = cache.style(forKey: "f", caretLocation: 4, caretHeight: 14, styleRun: { nil }) { small }
        let grown = cache.style(forKey: "f", caretLocation: 5, caretHeight: 28, styleRun: { nil }) { large }
        XCTAssertEqual(grown, large)
    }
}

/// A line box's source survives the cache's merges (see `HostTextMetrics.lineRectIsFromTextMarkers`):
/// the typographic caret refinement must never read a text-marker box as an index-based one.
@MainActor
final class HostTextMetricsCacheMarkerLineTests: XCTestCase {
    func testAMarkerLineBoxKeepsItsSourceThroughARemeasure() {
        let cache = HostTextMetricsCache()
        let start = Date(timeIntervalSince1970: 1_000)
        let markerLine = HostTextMetrics(
            lineRect: CGRect(x: 95, y: 300, width: 400, height: 19), lineRectIsFromTextMarkers: true
        )
        let sampleOnly = HostTextMetrics(sampleText: "Keep on veri", sampleWidth: 89)
        _ = cache.metrics(forKey: "f", caretLocation: 1, now: start) { markerLine }
        let merged = cache.metrics(forKey: "f", caretLocation: 9, now: start.addingTimeInterval(2)) { sampleOnly }
        XCTAssertEqual(merged?.sampleText, "Keep on veri")
        XCTAssertEqual(merged?.lineRect, markerLine.lineRect)
        XCTAssertEqual(merged?.lineRectIsFromTextMarkers, true)
    }
}

/// Which text-marker line boxes the probe believes (see `HostTextMetricsProbe.isCaretLine`).
@MainActor
final class HostTextMetricsProbeCaretLineTests: XCTestCase {
    private let field = CGRect(x: 88, y: 327, width: 546, height: 257)

    func testTheCaretsOwnLineIsBelieved() {
        let line = CGRect(x: 101, y: 540, width: 520, height: 29)
        let caret = CGRect(x: 400, y: 544, width: 1, height: 21)
        XCTAssertTrue(HostTextMetricsProbe.isCaretLine(line, caret: caret, anchor: field, caretHeight: 21))
    }

    /// Measured 2026-09-10 in Chrome: a box 696pt wide and 88pt tall above a 546pt field.
    func testABoxOutsideTheFieldOrTallerThanALineIsNot() {
        let caret = CGRect(x: 400, y: 544, width: 1, height: 21)
        XCTAssertFalse(HostTextMetricsProbe.isCaretLine(
            CGRect(x: 44, y: 585.5, width: 696, height: 88), caret: caret, anchor: field, caretHeight: 21
        ))
        XCTAssertFalse(HostTextMetricsProbe.isCaretLine(
            CGRect(x: 101, y: 400, width: 520, height: 60), caret: nil, anchor: field, caretHeight: 21
        ), "three lines tall is no line")
        XCTAssertFalse(HostTextMetricsProbe.isCaretLine(
            CGRect(x: 101, y: 400, width: 520, height: 29), caret: caret, anchor: field, caretHeight: 21
        ), "a line that does not hold the caret is another line")
    }
}

/// Marker lines from glyph boxes, with Claude's composer as measured on 2026-09-11 (Cocoa rects).
@MainActor
final class HostTextMetricsProbeMarkerLineTests: XCTestCase {
    private let composer = CGRect(x: 84, y: 862, width: 801, height: 48)

    /// The line range's box was the paragraph's padded block: x 84 for text at 95, 33pt tall.
    func testTheLineStartsAtItsFirstGlyphNotAtItsPaddedBox() throws {
        let padded = CGRect(x: 84, y: 866, width: 731, height: 33)
        let glyph = CGRect(x: 95, y: 871, width: 8, height: 19)
        let caret = CGRect(x: 813, y: 871, width: 0, height: 19)
        let line = try XCTUnwrap(HostTextMetricsProbe.markerLine(
            lineBox: padded, firstCharacter: glyph, previousLineBox: nil, previousFirstCharacter: nil,
            caret: caret, anchor: composer, caretHeight: 19
        ))
        XCTAssertEqual(line.rect.minX, 95)
        XCTAssertEqual(line.rect.height, 19)
        XCTAssertNil(line.pitch)
    }

    /// A wrapped paragraph's box spans both lines and fails the one-line check; the glyphs of the
    /// two lines still measure the pitch.
    func testTheGlyphsOfTwoLinesMeasureThePitchWhereTheBoxesSpanBoth() throws {
        let field = CGRect(x: 84, y: 842, width: 801, height: 68)
        let paragraph = CGRect(x: 84, y: 846, width: 790, height: 56)
        let lineTwo = CGRect(x: 95, y: 851, width: 8, height: 19)
        let lineOne = CGRect(x: 95, y: 874, width: 8, height: 19)
        let caret = CGRect(x: 300, y: 851, width: 0, height: 19)
        let line = try XCTUnwrap(HostTextMetricsProbe.markerLine(
            lineBox: paragraph, firstCharacter: lineTwo, previousLineBox: paragraph, previousFirstCharacter: lineOne,
            caret: caret, anchor: field, caretHeight: 19
        ))
        XCTAssertEqual(line.rect.minX, 95)
        XCTAssertEqual(try XCTUnwrap(line.pitch), 23, accuracy: 0.001)
    }

    /// Where the host's line boxes are glyph lines (the ProseMirror replica), nothing changes.
    func testGlyphLineBoxesMeasureTheSame() throws {
        let field = CGRect(x: 100, y: 747, width: 863, height: 77)
        let lineTwo = CGRect(x: 113, y: 767, width: 93, height: 20)
        let lineOne = CGRect(x: 113, y: 791, width: 700, height: 19)
        let line = try XCTUnwrap(HostTextMetricsProbe.markerLine(
            lineBox: lineTwo, firstCharacter: CGRect(x: 113, y: 767, width: 9, height: 20),
            previousLineBox: lineOne, previousFirstCharacter: CGRect(x: 113, y: 791, width: 9, height: 19),
            caret: CGRect(x: 206, y: 767, width: 0, height: 20), anchor: field, caretHeight: 20
        ))
        XCTAssertEqual(line.rect.minX, 113)
        XCTAssertEqual(try XCTUnwrap(line.pitch), 23.5, accuracy: 0.001)
    }

    /// A ProseMirror-style paragraph (a <p> per paragraph, no padding) frames one line box: in the
    /// composer replica in Chrome (2026-09-11) the caret's glyph box was 17pt and its paragraph 21pt,
    /// 14px at line-height 1.5, starting where the text does. In a browser a one-line paragraph takes
    /// that for its pitch before any second line exists; elsewhere nothing changes.
    func testAOneLineParagraphsBoxIsItsPitchInABrowser() throws {
        let field = CGRect(x: 96, y: 700, width: 784, height: 70)
        let glyph = CGRect(x: 108, y: 740, width: 9, height: 17)
        let paragraph = CGRect(x: 108, y: 738, width: 760, height: 21)
        func line(browser: Bool) -> (rect: CGRect, pitch: CGFloat?, pitchFromParagraph: Bool)? {
            HostTextMetricsProbe.markerLine(
                lineBox: CGRect(x: 108, y: 740, width: 73, height: 17), firstCharacter: glyph,
                previousLineBox: nil, previousFirstCharacter: nil,
                caret: CGRect(x: 181, y: 740, width: 0, height: 17), anchor: field, caretHeight: 17,
                paragraph: paragraph, allowsParagraphPitch: browser
            )
        }
        XCTAssertEqual(try XCTUnwrap(line(browser: true)?.pitch), 21, accuracy: 0.001)
        XCTAssertEqual(line(browser: true)?.pitchFromParagraph, true)
        XCTAssertNotNil(line(browser: false))
        XCTAssertNil(line(browser: false)?.pitch)
    }

    /// A block padded beside its text, or two lines tall, is not one line's box.
    func testAPaddedOrTwoLineParagraphIsNoLineBox() {
        let glyph = CGRect(x: 95, y: 871, width: 8, height: 19)
        XCTAssertNil(HostTextMetricsProbe.paragraphLinePitch(paragraph: CGRect(x: 84, y: 866, width: 731, height: 33), firstCharacter: glyph))
        XCTAssertNil(HostTextMetricsProbe.paragraphLinePitch(paragraph: CGRect(x: 95, y: 850, width: 731, height: 46), firstCharacter: glyph))
        XCTAssertEqual(HostTextMetricsProbe.paragraphLinePitch(paragraph: CGRect(x: 95, y: 869, width: 731, height: 23), firstCharacter: glyph), 23)
    }

    /// An empty line has no glyph: its box stands, and a frame-sized box is still no line.
    func testAnEmptyLineKeepsItsBoxAndAFrameSizedBoxIsDropped() {
        let empty = CGRect(x: 95, y: 868, width: 785, height: 20)
        XCTAssertEqual(HostTextMetricsProbe.markerLine(
            lineBox: empty, firstCharacter: nil, previousLineBox: nil, previousFirstCharacter: nil,
            caret: CGRect(x: 95, y: 868, width: 0, height: 20), anchor: composer, caretHeight: 20
        )?.rect.minX, 95)
        XCTAssertNil(HostTextMetricsProbe.markerLine(
            lineBox: composer, firstCharacter: nil, previousLineBox: nil, previousFirstCharacter: nil,
            caret: CGRect(x: 95, y: 868, width: 0, height: 20), anchor: composer, caretHeight: 20
        ))
    }

    /// Gmail's compose body in Chrome (2026-09-11): the caret line's range started at x 804, then
    /// 743, on a line whose text starts at 393 (15pt glyph boxes, a line 15pt above). The ranges
    /// before such a start on the same glyph row are earlier parts of the line; the line above, and
    /// text in a column further left, are not.
    func testALineRangeStartingPartwayAlongItsLineHasEarlierFragments() {
        let first = CGRect(x: 804, y: 220, width: 7, height: 15)
        XCTAssertTrue(AXHelper.isEarlierFragment(CGRect(x: 743, y: 220, width: 61, height: 15), ofLineStartingAt: first))
        XCTAssertTrue(AXHelper.isEarlierFragment(
            CGRect(x: 393, y: 220, width: 350, height: 15), ofLineStartingAt: CGRect(x: 743, y: 220, width: 8, height: 15)
        ))
        XCTAssertFalse(AXHelper.isEarlierFragment(CGRect(x: 393, y: 205, width: 1000, height: 15), ofLineStartingAt: first),
                       "the line above")
        XCTAssertFalse(AXHelper.isEarlierFragment(CGRect(x: 100, y: 220, width: 200, height: 15), ofLineStartingAt: first),
                       "a column further left")
        XCTAssertFalse(AXHelper.isEarlierFragment(CGRect(x: 393, y: 205, width: 411, height: 45), ofLineStartingAt: first),
                       "a block three lines tall")
    }
}

