import Combine
import Foundation
import FoundationModels

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

    let model: SystemLanguageModel

    init(model: SystemLanguageModel = .default) {
        self.model = model
        self.state = Self.map(model.availability)
    }

    /// Refreshes the cached availability before a generation attempt.
    /// Availability can change at runtime if the user enables Apple Intelligence or if the model
    /// finishes downloading in the background.
    func refresh() {
        state = Self.map(model.availability)
    }

    var isAvailable: Bool {
        state.isAvailable
    }

    var userVisibleMessage: String {
        state.summary
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
