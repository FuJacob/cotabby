import CoreGraphics

/// File overview:
/// Pure decision rule for the guided-permission helper overlay that floats over System Settings.
///
/// `PermissionGuidanceController` re-evaluates the overlay very often — a short repeating timer plus
/// an app-activation observer — so "what should the overlay do now?" must collapse to a no-op
/// whenever nothing actually changed. The previous controller logic hid the overlay and re-ordered
/// the window on *every* tick, so the helper flickered as focus bounced between System Settings, the
/// macOS permission dialog, and Cotabby's own windows. Keeping the rule pure makes the no-op paths
/// cheap to test.
nonisolated enum PermissionOverlayTracker {
    nonisolated enum Transition: Equatable {
        /// First appearance this session — the controller plays the fly-in animation.
        case present
        /// Move to / ensure visible at a new frame, without replaying the animation.
        case reposition
        case hide
        case none
    }

    /// Decides the next overlay action from the current state.
    ///
    /// - Parameters:
    ///   - settingsFrame: the frontmost System Settings window frame, or `nil` when System Settings
    ///     is not frontmost (e.g. the macOS permission dialog or Cotabby is in front).
    ///   - hasPresented: whether the overlay has been shown at least once since tracking started.
    ///   - isVisible: whether the overlay is currently on screen.
    ///   - lastFrame: the System Settings frame the overlay was last positioned against.
    static func transition(
        settingsFrame: CGRect?,
        hasPresented: Bool,
        isVisible: Bool,
        lastFrame: CGRect?
    ) -> Transition {
        guard let settingsFrame else {
            // System Settings isn't frontmost. Only act if we're actually showing something —
            // hiding an already-hidden overlay every tick is exactly what caused the flicker.
            return isVisible ? .hide : .none
        }

        guard hasPresented else {
            return .present
        }

        // Re-show after a hide, or follow the window when it moves — but never re-animate, and
        // never touch the window when it's already parked at the right spot.
        if !isVisible || settingsFrame != lastFrame {
            return .reposition
        }

        return .none
    }
}
