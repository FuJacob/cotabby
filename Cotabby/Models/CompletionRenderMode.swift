import Foundation

/// File overview:
/// Names the visual strategy `OverlayController` uses to surface a suggestion. The split exists
/// because some hosts expose unreliable caret geometry (Electron canvases, certain web editors).
/// Drawing inline ghost text in those hosts produces a "marching" effect as the caret estimate
/// drifts. Mirror mode sidesteps that by rendering the suggestion in a Cotabby-owned card anchored
/// to the input field rectangle, which is much more stable than the caret rect in those apps.
///
/// The enum lives in `Models/` rather than `Support/` because both the policy (which picks the mode)
/// and `OverlayState` (which records which mode the panel is currently in) need to spell out the
/// same case names without depending on rendering code.
nonisolated enum CompletionRenderMode: Equatable, Sendable {
    /// Ghost text drawn next to the live caret. The default for hosts with trustworthy AX geometry.
    case inline

    /// Suggestion drawn inside a Cotabby-owned card. Used when caret geometry is unreliable, or
    /// when the user explicitly prefers the preview-card presentation. The reason is informational
    /// only; the rendering pipeline does not branch on it.
    case mirror(reason: MirrorReason)

    /// Why mirror mode was chosen for this presentation. Surfaced in the focus debug overlay and
    /// in `OverlayState.detail` so operators can confirm the policy is firing as expected.
    nonisolated enum MirrorReason: String, Equatable, Sendable {
        /// Caret quality came back `.estimated`, meaning the host did not expose `AXBoundsForRange`
        /// or any of the derived geometry paths. Inline rendering would land at a guessed X that
        /// drifts as the user types.
        case caretGeometryEstimated

        /// The caret sits mid-line: real characters follow it before the next line break. Inline
        /// ghost text would draw on top of those trailing characters, so the suggestion is promoted
        /// to the card, which anchors to the caret rect (the geometry is trustworthy here) and sits
        /// just under the cursor like an inline ghost would. This is also the surface fill-in-middle
        /// completions render in, since a FIM result has no inline home.
        case caretMidLine

        /// User set their global preference to always use mirror mode. Phase 2 wiring.
        case userPreference

        /// Per-app override forced mirror mode for this host. Phase 2 wiring.
        case perAppOverride
    }

    /// Short, debug-friendly label for diagnostics and logs.
    var label: String {
        switch self {
        case .inline:
            return "inline"
        case .mirror(let reason):
            return "mirror(\(reason.rawValue))"
        }
    }

    var isMirror: Bool {
        if case .mirror = self {
            return true
        }
        return false
    }
}
