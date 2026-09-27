import Combine
import XCTest
@testable import Cotabby

/// Tests for `SuggestionFocusProviding.refreshIfStale`, the guard that lets the prediction
/// pipeline reuse a capture another caller performed moments earlier instead of paying a second
/// synchronous AX walk back to back. (The visual-capture path that deliberately bypasses this
/// reuse window is covered in `SuggestionCoordinatorLifecycleTests`.)
@MainActor
final class SuggestionFocusFreshnessTests: XCTestCase {
    /// The window is inclusive: a capture exactly `maxAgeMilliseconds` old is still reused, and an
    /// unknown age always pays the refresh.
    func test_refreshIfStale_refreshesOnlyWhenTheCaptureIsOlderThanTheWindowOrUnknown() {
        let cases: [(age: Int?, expectedRefreshes: Int)] = [(nil, 1), (31, 1), (30, 0), (10, 0)]

        for (age, expectedRefreshes) in cases {
            let provider = RecordingFocusProvider(millisecondsSinceLastCapture: age)
            provider.refreshIfStale(maxAgeMilliseconds: 30)
            XCTAssertEqual(provider.refreshCount, expectedRefreshes, "capture age \(String(describing: age)) ms")
        }
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
