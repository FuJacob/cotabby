import Foundation
import XCTest
@testable import Cotabby

/// Locks the availability facade around Apple Intelligence: the binary-decision vocabulary the
/// rest of the app consumes, the refresh transition logging branch, and the observation wiring
/// that pushes provider changes into the published state. The real `SystemLanguageModel` provider
/// is OS-state-dependent and deliberately untested here; the protocol seam exists precisely so
/// this contract can be locked deterministically.
@MainActor
final class FoundationModelAvailabilityServiceTests: XCTestCase {
    /// Production @MainActor classes deallocate through the buggy back-deploy executor shim in
    /// this app-hosted runner; quarantine instances for the process lifetime.
    private static var retained: [AnyObject] = []

    @MainActor
    private final class FakeProvider: FoundationModelAvailabilityProviding {
        var currentState: FoundationModelAvailabilityState
        var refreshResult: FoundationModelAvailabilityState
        private(set) var onChange: (@MainActor (FoundationModelAvailabilityState) -> Void)?

        init(initial: FoundationModelAvailabilityState) {
            currentState = initial
            refreshResult = initial
        }

        func refresh() -> FoundationModelAvailabilityState {
            refreshResult
        }

        func observe(
            onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void
        ) -> Task<Void, Never>? {
            self.onChange = onChange
            return nil
        }
    }

    private func makeService(
        initial: FoundationModelAvailabilityState
    ) -> (service: FoundationModelAvailabilityService, provider: FakeProvider) {
        let provider = FakeProvider(initial: initial)
        let service = FoundationModelAvailabilityService(provider: provider)
        Self.retained.append(service)
        return (service, provider)
    }

    func test_state_vocabularyExposesBinaryDecisionPlusExplanation() {
        XCTAssertTrue(FoundationModelAvailabilityState.available.isAvailable)
        XCTAssertEqual(
            FoundationModelAvailabilityState.available.summary,
            "Apple Intelligence is available."
        )
        let unavailable = FoundationModelAvailabilityState.unavailable("Model still downloading.")
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertEqual(unavailable.summary, "Model still downloading.")
    }

    func test_init_publishesTheProvidersCurrentStateAndStartsObserving() {
        let (service, provider) = makeService(initial: .unavailable("Turned off."))

        XCTAssertFalse(service.isAvailable)
        XCTAssertEqual(service.userVisibleMessage, "Turned off.")
        XCTAssertNotNil(provider.onChange, "The service must subscribe to provider changes at init")
    }

    func test_refresh_adoptsTheProvidersNewStateAcrossTheChangeBoundary() {
        let (service, provider) = makeService(initial: .unavailable("Downloading."))

        // No-change refresh keeps the state (and skips the transition log branch).
        service.refresh()
        XCTAssertEqual(service.userVisibleMessage, "Downloading.")

        // A real transition is adopted and exposed through both conveniences.
        provider.refreshResult = .available
        service.refresh()
        XCTAssertTrue(service.isAvailable)
        XCTAssertEqual(service.userVisibleMessage, "Apple Intelligence is available.")
    }

    func test_observation_pushesProviderChangesIntoThePublishedState() {
        let (service, provider) = makeService(initial: .available)

        provider.onChange?(.unavailable("User disabled Apple Intelligence."))

        XCTAssertFalse(service.isAvailable)
        XCTAssertEqual(service.userVisibleMessage, "User disabled Apple Intelligence.")
    }
}
