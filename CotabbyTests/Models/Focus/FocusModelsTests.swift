import Foundation
import XCTest
@testable import Cotabby

/// Tests for the pure focus value models: resolved field style emptiness and the polling-event
/// change label.
final class FocusModelsTests: XCTestCase {
    func test_resolvedFieldStyle_isEmptyWhenNoRenderableAttributeIsPresent() {
        let empty = ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: nil)
        XCTAssertTrue(empty.isEmpty)

        let fontOnly = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: nil, colorHex: nil)
        XCTAssertFalse(fontOnly.isEmpty)

        let colorOnly = ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: "336699")
        XCTAssertFalse(colorOnly.isEmpty)
    }

    func test_resolvedFieldStyle_pointSizeAloneIsARenderableStyle() {
        // Chromium reports only the size. That is the single most important fact for matching the
        // host's rendering, so a size-only style must survive to the font resolver.
        let style = ResolvedFieldStyle(fontName: nil, fontPointSize: 13, colorHex: nil)
        XCTAssertFalse(style.isEmpty)
        XCTAssertTrue(ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: nil).isEmpty)
        XCTAssertFalse(ResolvedFieldStyle(fontName: nil, fontFamily: "Georgia", fontPointSize: nil, colorHex: nil).isEmpty)
    }

    func test_focusPollingEvent_changeSummaryLabelsReflectFocusChange() {
        XCTAssertEqual(makePollingEvent(didChange: true).changeSummary, "changed")
        XCTAssertEqual(makePollingEvent(didChange: false).changeSummary, "unchanged")
    }

    private func makePollingEvent(didChange: Bool) -> FocusPollingEvent {
        FocusPollingEvent(
            sequence: 1,
            focusChangeSequence: 2,
            didChangeFocusedInput: didChange,
            applicationName: "Notes",
            capabilitySummary: "Supported",
            occurredAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
}
