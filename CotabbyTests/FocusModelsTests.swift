import Foundation
import XCTest
@testable import Cotabby

/// Tests for the pure focus value models: resolved field style emptiness, menu-facing capability
/// summaries, and the polling-event change label.
final class FocusModelsTests: XCTestCase {
    func test_resolvedFieldStyle_isEmptyWhenNoRenderableAttributeIsPresent() {
        let empty = ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: nil)
        XCTAssertTrue(empty.isEmpty)

        let fontOnly = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: nil, colorHex: nil)
        XCTAssertFalse(fontOnly.isEmpty)

        let colorOnly = ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: "336699")
        XCTAssertFalse(colorOnly.isEmpty)
    }

    func test_resolvedFieldStyle_pointSizeAloneIsNotARenderableStyle() {
        // A bare point size cannot style ghost text without a font or color, so it must still
        // count as empty and let the overlay fall back to defaults.
        let sizeOnly = ResolvedFieldStyle(fontName: nil, fontPointSize: 13, colorHex: nil)
        XCTAssertTrue(sizeOnly.isEmpty)
    }

    func test_focusSnapshot_capabilitySummaryForwardsTheCapabilityReason() {
        XCTAssertEqual(FocusSnapshot.inactive.capabilitySummary, "No focused text input")

        let supported = FocusSnapshot(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            capability: .supported,
            context: nil,
            inspection: nil
        )
        XCTAssertEqual(supported.capabilitySummary, "Supported")

        let blocked = FocusSnapshot(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            capability: .blocked("Secure text field"),
            context: nil,
            inspection: nil
        )
        XCTAssertEqual(blocked.capabilitySummary, "Secure text field")
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
