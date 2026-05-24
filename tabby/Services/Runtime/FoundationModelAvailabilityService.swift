import Combine
import Foundation
import Logging

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Describes whether the Apple on-device language model can be used right now.
/// We keep the enum small because the rest of the app only needs a binary decision plus a
/// user-facing explanation.
enum FoundationModelAvailabilityState: Equatable, Sendable {
    case available
    case unavailable(String)

    var summary: String {
        switch self {
        case .available:
            return "Apple Intelligence is available."
        case .unavailable(let reason):
            return reason
        }
    }

    var isAvailable: Bool {
        if case .available = self {
            return true
        }

        return false
    }
}

/// File overview:
/// Wraps `SystemLanguageModel.default` behind a small app-owned service.
/// This keeps Apple Intelligence availability checks out of views and coordinators so the rest of
/// the app can ask one question: "can I send a request right now?"
@MainActor
final class FoundationModelAvailabilityService: ObservableObject {
    @Published private(set) var state: FoundationModelAvailabilityState

    private let provider: any FoundationModelAvailabilityProviding
    private var observationTask: Task<Void, Never>?

    init(provider: (any FoundationModelAvailabilityProviding)? = nil) {
        let resolvedProvider = provider ?? Self.makeDefaultProvider()

        self.provider = resolvedProvider
        self.state = resolvedProvider.currentState

        startObserving()
    }

    /// Refreshes the cached availability before a generation attempt.
    /// Availability can change at runtime if the user enables Apple Intelligence or if the model
    /// finishes downloading in the background.
    func refresh() {
        let previousState = state
        state = provider.refresh()
        if state != previousState {
            TabbyLogger.runtime.info("Foundation model availability changed: \(self.state.summary)")
        }
    }

    var isAvailable: Bool {
        state.isAvailable
    }

    var userVisibleMessage: String {
        state.summary
    }

    /// Starts a reactive observation loop so availability changes propagate to the UI without
    /// manual `refresh()` calls. The provider owns the observation mechanism: the system provider
    /// watches `SystemLanguageModel.availability` via Swift Observation, while the unsupported
    /// provider is a no-op since its state never changes.
    private func startObserving() {
        observationTask = provider.observe { [weak self] newState in
            self?.state = newState
        }
    }
}

/// Abstracts the availability state and refresh operation for the Apple Intelligence backend.
/// `FoundationModelAvailabilityService` owns the provider and publishes its state to engines and
/// UI-facing objects; providers own the OS-specific details. Keeping this as a protocol lets tests
/// inject deterministic states and lets app composition swap in an unsupported implementation on
/// older macOS versions without touching FoundationModels-only symbols.
@MainActor
protocol FoundationModelAvailabilityProviding {
    /// The most recently known app-level availability state exposed to the service.
    var currentState: FoundationModelAvailabilityState { get }

    /// Re-reads provider-specific availability and returns it in Tabby's app-level vocabulary.
    func refresh() -> FoundationModelAvailabilityState

    /// Returns a long-lived task that calls `onChange` whenever availability changes.
    /// The system provider uses Swift Observation to watch `SystemLanguageModel`; the unsupported
    /// provider returns nil because its state is constant.
    func observe(onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void) -> Task<Void, Never>?
}

/// Reports a stable unavailable state for the Apple Intelligence backend.
/// This provider collaborates with `FoundationModelAvailabilityService` in the same shape as the
/// real system provider, which keeps the service from branching on OS support. It exists as its own
/// type to protect older macOS builds from constructing or importing FoundationModels runtime
/// objects while still giving the rest of the app a clear user-facing reason; `refresh()` is
/// intentionally constant because unsupported runtime state cannot become available in-process.
@MainActor
private struct UnsupportedFoundationModelAvailabilityProvider: FoundationModelAvailabilityProviding {
    let currentState: FoundationModelAvailabilityState

    init(reason: String) {
        currentState = .unavailable(reason)
    }

    func refresh() -> FoundationModelAvailabilityState {
        currentState
    }

    func observe(onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void) -> Task<Void, Never>? {
        nil
    }
}

extension FoundationModelAvailabilityService {
    private static func makeDefaultProvider() -> any FoundationModelAvailabilityProviding {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemFoundationModelAvailabilityProvider()
        }
        #endif

        return UnsupportedFoundationModelAvailabilityProvider(
            reason: "Apple Intelligence requires macOS 26 or later. Use Open Source on this Mac."
        )
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
extension FoundationModelAvailabilityService {
    var systemLanguageModel: SystemLanguageModel? {
        // In production, `.available` can only come from `SystemFoundationModelAvailabilityProvider`,
        // the provider installed by `makeDefaultProvider` on macOS 26+. The optional keeps tests and
        // future injected providers from accidentally relying on a FoundationModels instance they
        // do not own.
        (provider as? SystemFoundationModelAvailabilityProvider)?.model
    }
}

/// Owns the real `SystemLanguageModel` instance used by the Apple Intelligence backend.
/// It collaborates with `FoundationModelAvailabilityService` to publish framework availability and
/// with `FoundationModelSuggestionEngine` by handing out the model after runtime checks pass. It is
/// separate from the unsupported provider because it is the only implementation allowed to
/// construct FoundationModels objects and map `SystemLanguageModel.Availability` into Tabby's
/// app-level availability state before engines or UI read it.
@available(macOS 26.0, *)
@MainActor
private final class SystemFoundationModelAvailabilityProvider: FoundationModelAvailabilityProviding {
    let model: SystemLanguageModel

    init() {
        model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
    }

    var currentState: FoundationModelAvailabilityState {
        Self.map(model.availability)
    }

    func refresh() -> FoundationModelAvailabilityState {
        Self.map(model.availability)
    }

    /// Uses Swift Observation to watch `SystemLanguageModel.availability` and push changes
    /// back to the service. `withObservationTracking` fires once per change, so the loop
    /// re-registers after each callback to stay subscribed for the lifetime of the task.
    func observe(onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void) -> Task<Void, Never>? {
        let observedModel = model
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let newState: FoundationModelAvailabilityState? = await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = observedModel.availability
                    } onChange: {
                        Task { @MainActor in
                            guard self != nil else {
                                continuation.resume(returning: nil)
                                return
                            }
                            continuation.resume(returning: Self.map(observedModel.availability))
                        }
                    }
                }
                guard let newState else { break }
                onChange(newState)
            }
        }
    }

    private static func map(
        _ availability: SystemLanguageModel.Availability
    ) -> FoundationModelAvailabilityState {
        switch availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac is not eligible for Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is turned off in System Settings.")
        case .unavailable(.modelNotReady):
            return .unavailable("The Apple on-device model is still preparing or downloading.")
        @unknown default:
            return .unavailable("The Apple on-device model is unavailable for an unknown reason.")
        }
    }
}
#endif
