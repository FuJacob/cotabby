import Foundation
@testable import Cotabby

/// Deterministic availability source for the Apple Intelligence suites, which cannot depend on
/// whether the machine running the tests has Apple Intelligence enabled.
@MainActor
final class FakeFoundationModelAvailabilityProvider: FoundationModelAvailabilityProviding {
    var currentState: FoundationModelAvailabilityState
    var refreshResult: FoundationModelAvailabilityState
    private(set) var refreshCount = 0
    /// The observer the service registered, so a test can push a system-side change through it.
    private(set) var onChange: (@MainActor (FoundationModelAvailabilityState) -> Void)?

    /// `refreshResult` defaults to `current` for tests where a refresh should change nothing.
    init(current: FoundationModelAvailabilityState, refreshResult: FoundationModelAvailabilityState? = nil) {
        currentState = current
        self.refreshResult = refreshResult ?? current
    }

    func refresh() -> FoundationModelAvailabilityState {
        refreshCount += 1
        return refreshResult
    }

    func observe(onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void) {
        self.onChange = onChange
    }
}
