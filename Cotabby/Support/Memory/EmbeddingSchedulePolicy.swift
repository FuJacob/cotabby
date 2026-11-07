import Foundation

/// File overview:
/// When conversation memory may embed passages in the background.
///
/// Why a policy of its own: embedding a mailbox keeps the GPU busy for minutes, which is fine on a
/// plugged-in, idle, cool Mac and wrong on battery, in Low Power Mode, under thermal pressure, or
/// while the user is typing and Cotabby is generating a suggestion that needs the same GPU. A
/// handful of new messages (the usual delta after a sync) is cheap and should become searchable
/// right away, whatever the conditions short of heat. Pure, so each rule is pinned by a test.
nonisolated enum EmbeddingSchedulePolicy {
    struct Conditions: Equatable, Sendable {
        var isOnACPower: Bool
        var isLowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState
        /// Seconds since the user's last keyboard or mouse input.
        var userIdleSeconds: TimeInterval
        /// A suggestion is being generated right now.
        var isGenerating: Bool
        /// Passages waiting to be embedded.
        var pendingPassages: Int
    }

    enum Decision: Equatable, Sendable {
        case run
        case wait(String)
    }

    /// Up to this many pending passages are embedded whatever the power state.
    static let smallDeltaLimit = 200
    /// A large backlog waits for this much user inactivity.
    static let requiredIdleSeconds: TimeInterval = 20

    static func decide(_ conditions: Conditions) -> Decision {
        guard conditions.pendingPassages > 0 else { return .wait("Nothing to index") }
        switch conditions.thermalState {
        case .serious, .critical: return .wait("Waiting for the Mac to cool down")
        default: break
        }
        if conditions.isGenerating { return .wait("Waiting for the current suggestion") }
        if conditions.pendingPassages <= smallDeltaLimit { return .run }
        guard conditions.isOnACPower else { return .wait("Waiting for power: indexing runs while plugged in") }
        guard !conditions.isLowPowerMode else { return .wait("Paused in Low Power Mode") }
        guard conditions.thermalState == .nominal || conditions.thermalState == .fair else {
            return .wait("Waiting for the Mac to cool down")
        }
        guard conditions.userIdleSeconds >= requiredIdleSeconds else { return .wait("Waiting until you pause typing") }
        return .run
    }
}
