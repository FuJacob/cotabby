import CoreGraphics

/// File overview:
/// Pure decision rule for the guided-permission helper overlay that floats over System Settings.
///
/// `PermissionGuidanceController` re-evaluates the overlay very often — a short repeating timer plus
/// an app-activation observer — so "what should the overlay do now?" must collapse to a no-op
/// whenever nothing actually changed. Hiding the overlay or re-ordering the window on *every* tick
/// makes the helper flicker as focus bounces between System Settings, the macOS permission dialog,
/// and Cotabby's own windows. Keeping the rule pure makes the no-op paths cheap to test.
nonisolated enum PermissionOverlayTracker {
    nonisolated enum Transition: Equatable {
        /// First appearance this session — the controller plays the fly-in animation.
        case present
        /// Move to / ensure visible at a new frame, without replaying the animation.
        case reposition
        case hide
        case none
    }

    /// Decides the next overlay action and the phase the overlay is in once it has been applied.
    ///
    /// - Parameters:
    ///   - settingsFrame: the frontmost System Settings window frame, or `nil` when System Settings
    ///     is not frontmost (e.g. the macOS permission dialog or Cotabby is in front).
    ///   - phase: the overlay's current phase.
    static func transition(
        settingsFrame: CGRect?,
        phase: PermissionOverlayPhase
    ) -> (transition: Transition, next: PermissionOverlayPhase) {
        guard let settingsFrame else {
            // System Settings isn't frontmost. Only act if we're actually showing something —
            // hiding an already-hidden overlay every tick is exactly what caused the flicker.
            if case .visible = phase {
                return (.hide, .hidden)
            }
            return (.none, phase)
        }

        switch phase {
        case .notPresented:
            return (.present, .visible(at: settingsFrame))
        case .hidden:
            // Re-show after a hide, but never re-animate.
            return (.reposition, .visible(at: settingsFrame))
        case .visible(let lastFrame):
            // Follow the window when it moves, and never touch it when it is already parked at
            // the right spot.
            if settingsFrame == lastFrame {
                return (.none, phase)
            }
            return (.reposition, .visible(at: settingsFrame))
        }
    }
}

/// Where the guided-permission helper overlay is in its life for one guidance session.
///
/// One value instead of separate "has presented", "is visible" and "last frame" fields, so the
/// combinations that cannot happen (visible without a frame, never presented yet visible) cannot
/// be written down either.
nonisolated enum PermissionOverlayPhase: Equatable {
    /// Not shown yet this session; the first appearance plays the fly-in animation.
    case notPresented
    /// On screen, positioned against this System Settings window frame.
    case visible(at: CGRect)
    /// Shown earlier and currently ordered out because System Settings is not frontmost.
    case hidden
}
