import Combine
import XCTest
@testable import Cotabby

/// Tests for `SuggestionFocusProviding.refreshIfStale`, the guard that lets the prediction
/// pipeline reuse a capture another caller performed moments earlier instead of paying a second
/// synchronous AX walk back to back.
@MainActor
final class SuggestionFocusFreshnessTests: XCTestCase {
    func test_visualCaptureRefreshesEvenImmediatelyAfterPoll() {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        XCTAssertNotNil(rig.focusProvider.snapshot.context)
        rig.focusProvider.millisecondsSinceLastCapture = 1
        rig.focusProvider.onRefresh = { [weak focus = rig.focusProvider] in
            focus?.snapshot = .inactive
        }
        let previousRefreshCount = rig.focusProvider.refreshCount

        XCTAssertNil(rig.coordinator.currentVisualRefreshContext())
        XCTAssertEqual(rig.focusProvider.refreshCount, previousRefreshCount + 1)
        XCTAssertNil(rig.focusProvider.snapshot.context)
    }

    func test_refreshIfStale_refreshesWhenAgeUnknown() {
        let provider = RecordingFocusProvider(millisecondsSinceLastCapture: nil)
        provider.refreshIfStale(maxAgeMilliseconds: 30)
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func test_refreshIfStale_refreshesWhenCaptureOlderThanWindow() {
        let provider = RecordingFocusProvider(millisecondsSinceLastCapture: 31)
        provider.refreshIfStale(maxAgeMilliseconds: 30)
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func test_refreshIfStale_skipsWhenCaptureFresh() {
        let provider = RecordingFocusProvider(millisecondsSinceLastCapture: 10)
        provider.refreshIfStale(maxAgeMilliseconds: 30)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func test_refreshIfStale_boundaryAgeCountsAsFresh() {
        let provider = RecordingFocusProvider(millisecondsSinceLastCapture: 30)
        provider.refreshIfStale(maxAgeMilliseconds: 30)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    /// Fakes that do not implement the age accessor must keep today's always-refresh behavior, so
    /// adding freshness can never silently weaken a test double's refresh expectations.
    func test_defaultConformance_reportsUnknownAge() {
        let provider = MinimalFocusProvider()
        XCTAssertNil(provider.millisecondsSinceLastCapture)
        provider.refreshIfStale(maxAgeMilliseconds: 1000)
        XCTAssertEqual(provider.refreshCount, 1)
    }
}

@MainActor
private final class RecordingFocusProvider: SuggestionFocusProviding {
    let snapshot = FocusSnapshot.inactive
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        Empty().eraseToAnyPublisher()
    }

    let millisecondsSinceLastCapture: Int?
    private(set) var refreshCount = 0

    init(millisecondsSinceLastCapture: Int?) {
        self.millisecondsSinceLastCapture = millisecondsSinceLastCapture
    }

    func refreshNow() {
        refreshCount += 1
    }
}

@MainActor
private final class MinimalFocusProvider: SuggestionFocusProviding {
    let snapshot = FocusSnapshot.inactive
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        Empty().eraseToAnyPublisher()
    }

    private(set) var refreshCount = 0

    func refreshNow() {
        refreshCount += 1
    }
}
