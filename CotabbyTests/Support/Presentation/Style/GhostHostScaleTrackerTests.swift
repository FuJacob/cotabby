import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the per-field memory of a host's display scale (its zoom). The contract: a scale
/// learned from a precise render is available to later renders in the same field, is never erased by
/// a render that could not measure, and never leaks into another field.
@MainActor
final class GhostHostScaleTrackerTests: XCTestCase {
    func test_scaleIsUnknownUntilOneIsRecorded() {
        let tracker = GhostHostScaleTracker()
        XCTAssertNil(tracker.scale(forFocusSessionKey: 1))
    }

    func test_recordedScaleIsAvailableForItsField() {
        var tracker = GhostHostScaleTracker()
        tracker.record(2, focusSessionKey: 1)

        XCTAssertEqual(tracker.scale(forFocusSessionKey: 1), 2)
    }

    func test_aRenderThatCouldNotMeasureKeepsTheEarlierScale() {
        // A precise caret whose typeface had not loaded yet yields no scale; that must not erase
        // the zoom a previous render learned.
        var tracker = GhostHostScaleTracker()
        tracker.record(2, focusSessionKey: 1)
        tracker.record(nil, focusSessionKey: 1)

        XCTAssertEqual(tracker.scale(forFocusSessionKey: 1), 2)
    }

    func test_aNewerMeasurementReplacesTheScale() {
        // The user zoomed: the next precise render re-learns it.
        var tracker = GhostHostScaleTracker()
        tracker.record(2, focusSessionKey: 1)
        tracker.record(1.5, focusSessionKey: 1)

        XCTAssertEqual(tracker.scale(forFocusSessionKey: 1), 1.5)
    }

    func test_switchingFieldsForgetsThePreviousFieldsScale() {
        var tracker = GhostHostScaleTracker()
        tracker.record(2, focusSessionKey: 1)
        tracker.record(nil, focusSessionKey: 2)

        XCTAssertNil(tracker.scale(forFocusSessionKey: 2))
        XCTAssertNil(tracker.scale(forFocusSessionKey: 1), "the old field's zoom is dropped, not kept aside")
    }
}
