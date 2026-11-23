import Foundation

/// File overview:
/// Pure lifecycle of `InputMonitor`'s consuming accept tap. The monitor owns the CoreGraphics tap
/// handle and the timers; this value decides what should happen to the tap and when, so the rules
/// that keep keystrokes from being dropped can be tested without installing a global event tap.
///
/// The tap is on the synchronous event path only while something needs it (issue #328), and it is
/// never switched off between the keystrokes of a burst: switching an active tap off pulls it out
/// of the session tap chain, and an event still on its way through it is lost. A final-chunk accept
/// runs *inside* the tap's own callback, posts the synthetic insertion, then hides the overlay, and
/// tearing the tap down in that same run-loop turn once made the last accepted word never reach the
/// host (PR #385). The user's own keystrokes are exposed the same way: toggling the tap around
/// every keystroke of a burst dropped about one typed character in a hundred in live TextEdit runs.
nonisolated struct AcceptTapLifecycle: Equatable {
    /// The independent reasons to keep the tap intercepting. A visible suggestion needs to consume
    /// the accept key; an in-progress emoji capture needs to consume navigation and commit keys.
    /// Tracking them separately means neither feature releases the tap while the other needs it.
    nonisolated struct Reasons: OptionSet, Equatable {
        let rawValue: Int

        static let suggestion = Reasons(rawValue: 1 << 0)
        static let emojiCapture = Reasons(rawValue: 1 << 1)
    }

    nonisolated enum Phase: Equatable {
        /// No tap is installed.
        case absent
        /// A reason wants the tap and Accessibility is granted: installed and enabled.
        case intercepting
        /// Nothing wants the tap; waiting for input to go quiet before switching it off.
        /// `tapEnabled` is false when the last reason change found the tap already parked: the
        /// wait restarts so a typing burst keeps the parked tap around for its next suggestion,
        /// but the tap itself stays off.
        case lingering(generation: UInt64, tapEnabled: Bool)
        /// Disabled but still installed, so the next suggestion only has to re-enable it instead
        /// of paying a synchronous WindowServer round trip (~20-30 ms measured) to re-create it.
        case parked(generation: UInt64)
    }

    /// What the monitor must do to the real tap after a transition.
    nonisolated enum Effect: Equatable {
        case none
        /// Make sure a tap exists and is intercepting. `reenableParkedTap` is true when an
        /// installed tap is known to be disabled; a missing tap is created either way.
        case intercept(reenableParkedTap: Bool)
        /// Call `idleCheckFired` with this generation after `delay`.
        case scheduleIdleCheck(generation: UInt64, delay: TimeInterval)
        /// Disable the tap when `disableTap` is set, then call `releaseFired` with this generation
        /// after `delay`.
        case park(disableTap: Bool, releaseGeneration: UInt64, delay: TimeInterval)
        /// Invalidate the tap.
        case release
    }

    /// How long the tap stays enabled after the last reason went away. Two seconds spans a typing
    /// burst, so the tap is only switched off once input has gone quiet, and it also covers the
    /// synthetic-insertion drain after a final-chunk accept.
    static let idleDisableSeconds: TimeInterval = 2
    /// How long a disabled tap is kept for its next suggestion before it is released.
    static let releaseDelaySeconds: TimeInterval = 10

    private(set) var reasons: Reasons = []
    private(set) var phase: Phase = .absent
    /// Bumped on every reason change. A pending timer only acts when its generation is still the
    /// phase's, so a stale callback (say, a release scheduled before the tap was re-armed and
    /// disabled again) cannot cut a newer idle period short.
    private var generation: UInt64 = 0

    /// Whether the consuming tap owns accept-key semantics. Only a visible suggestion claims the
    /// accept key: when the tap exists solely for emoji capture, the observer must keep routing the
    /// accept key to the coordinator so the emoji controller, not the suggestion accept path, acts
    /// on it. False the moment the tap stops being wanted, so the observer resumes passing keys
    /// through immediately.
    var ownsAcceptKeys: Bool {
        phase == .intercepting && reasons.contains(.suggestion)
    }

    /// Whether an installed tap is meant to be enabled. Distinguishes an intentional pause from
    /// the system disabling the tap on timeout, which the tap callback undoes.
    var isTapEnabled: Bool {
        switch phase {
        case .intercepting:
            return true
        case .lingering(_, let tapEnabled):
            return tapEnabled
        case .absent, .parked:
            return false
        }
    }

    /// Records that a reason started or stopped wanting the tap. A reason set without permission
    /// is remembered but does not arm the tap; the next reason change after a grant does.
    mutating func setReason(_ reason: Reasons, active: Bool, hasPermission: Bool) -> Effect {
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        generation &+= 1

        if hasPermission, !reasons.isEmpty {
            let reenableParkedTap = phase != .absent && !isTapEnabled
            phase = .intercepting
            return .intercept(reenableParkedTap: reenableParkedTap)
        }

        switch phase {
        case .absent:
            return .none
        case .intercepting, .lingering, .parked:
            phase = .lingering(generation: generation, tapEnabled: isTapEnabled)
            return .scheduleIdleCheck(generation: generation, delay: Self.idleDisableSeconds)
        }
    }

    /// The idle timer for `generation` fired. The quiet period is measured from the last keydown,
    /// not from the reason change: the user can keep typing long after the last suggestion hid,
    /// and that burst must not see the tap switch off. Permission is re-read here because a grant
    /// can make remembered reasons count again without any reason change.
    mutating func idleCheckFired(
        generation firedGeneration: UInt64,
        hasPermission: Bool,
        lastKeyDownUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Effect {
        guard case .lingering(firedGeneration, let tapEnabled) = phase,
              !(hasPermission && !reasons.isEmpty) else {
            return .none
        }
        let remaining = Self.idleRemaining(lastKeyDownUptime: lastKeyDownUptime, nowUptime: nowUptime)
        if remaining > 0 {
            return .scheduleIdleCheck(generation: firedGeneration, delay: remaining)
        }
        phase = .parked(generation: firedGeneration)
        return .park(disableTap: tapEnabled, releaseGeneration: firedGeneration, delay: Self.releaseDelaySeconds)
    }

    /// The release timer for `generation` fired.
    mutating func releaseFired(generation firedGeneration: UInt64, hasPermission: Bool) -> Effect {
        guard phase == .parked(generation: firedGeneration),
              !(hasPermission && !reasons.isEmpty) else {
            return .none
        }
        phase = .absent
        return .release
    }

    /// The monitor tore the tap down outside this lifecycle (it stopped, or permission was
    /// revoked). Reasons are kept: the tap is re-armed by the next reason change, not by a grant.
    mutating func tapRemoved() {
        phase = .absent
    }

    /// Seconds until input will have been quiet for `idleDisableSeconds`, or 0 once it has.
    static func idleRemaining(lastKeyDownUptime: TimeInterval?, nowUptime: TimeInterval) -> TimeInterval {
        guard let lastKeyDownUptime else { return 0 }
        return max(0, idleDisableSeconds - max(0, nowUptime - lastKeyDownUptime))
    }
}
