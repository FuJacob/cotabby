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
