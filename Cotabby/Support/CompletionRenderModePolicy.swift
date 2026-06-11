import Foundation

/// User-facing preference for how Cotabby presents completions.
///
/// `auto` defers to caret-geometry quality: trustworthy geometry stays inline, weak geometry promotes
/// to mirror mode. `alwaysInline` and `alwaysMirror` let power users pin a strategy when the
/// auto rule misfires for their host mix.
///
/// The global preference is live (Appearance settings Picker); per-app overrides are not wired yet.
/// Note that a mid-line caret promotes inline to the card regardless of this preference; see
/// `CompletionRenderModePolicy.mode(for:bundleIdentifier:)`.
enum MirrorPreference: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case auto
    case alwaysInline
    case alwaysMirror

    var id: String { rawValue }

    /// Human-readable label for Settings UI and the menu bar pop-up. Kept here so the UI code does
    /// not have to repeat the mapping; the policy is the single source of truth for both the rule
    /// and the copy. Phrased in user-facing terms ("popup") rather than the internal "mirror" name.
    var displayLabel: String {
        switch self {
        case .auto:
            return "Auto"
        case .alwaysInline:
            return "Inline"
        case .alwaysMirror:
            return "Popup"
        }
    }
}

/// Pure rule that translates "what kind of geometry do we have, and what does the user want?" into
/// the concrete `CompletionRenderMode` the overlay should use right now.
///
/// Pulling the decision into its own value type keeps `OverlayController` focused on AppKit layout
/// and makes the rule trivially unit-testable. Adding a new trigger (per-domain, telemetry-driven,
/// etc.) means editing this one struct rather than threading conditionals through the controller.
///
/// `Sendable` because the policy is a pure value type built from `Sendable` members; explicit
/// `nonisolated init` keeps the default-parameter expression `CompletionRenderModePolicy()` from
/// being inferred as `@MainActor`-isolated when used as a default in main-actor classes.
struct CompletionRenderModePolicy: Equatable, Sendable {
    let userPreference: MirrorPreference

    /// Per-app override map keyed by bundle identifier. Empty in Phase 1; populated by Settings in
    /// Phase 2. A bundle in this map wins over `userPreference`.
    let perAppOverrides: [String: MirrorPreference]

    nonisolated init(
        userPreference: MirrorPreference = .auto,
        perAppOverrides: [String: MirrorPreference] = [:]
    ) {
        self.userPreference = userPreference
        self.perAppOverrides = perAppOverrides
    }

    /// Decides which render mode to use for one presentation. `bundleIdentifier` may be nil when the
    /// host app could not be identified; in that case only the global preference applies.
    func mode(
        for geometry: SuggestionOverlayGeometry,
        bundleIdentifier: String?
    ) -> CompletionRenderMode {
        let baseMode = preferenceMode(for: geometry, bundleIdentifier: bundleIdentifier)

        // A caret parked mid-line (real characters follow it before the next line break) has no
        // inline home: ghost text would paint over those trailing characters. Promote any inline
        // result to the card, which anchors to the caret rect (the geometry is trustworthy here). This
        // deliberately overrides an explicit `.alwaysInline` pin too, because inline cannot render
        // mid-line at all, and the card is the surface fill-in-middle completions will use. The
        // promotion only upgrades inline results; a presentation already routed to the card keeps its
        // original, more specific reason (e.g. `.caretGeometryEstimated`).
        if case .inline = baseMode, !geometry.isCaretAtEndOfLine {
            return .mirror(reason: .caretMidLine)
        }
        return baseMode
    }

    /// The render mode implied by the user (or per-app) preference and caret-geometry quality, before
    /// the mid-line override in `mode(for:bundleIdentifier:)` is applied. Split out so that override
    /// reads as a single, well-scoped rule rather than another branch threaded through the switch.
    private func preferenceMode(
        for geometry: SuggestionOverlayGeometry,
        bundleIdentifier: String?
    ) -> CompletionRenderMode {
        let effectivePreference: MirrorPreference
        if let bundleIdentifier, let override = perAppOverrides[bundleIdentifier] {
            effectivePreference = override
        } else {
            effectivePreference = userPreference
        }

        switch effectivePreference {
        case .alwaysInline:
            return .inline

        case .alwaysMirror:
            // The per-app branch is recorded separately because the user-set "always mirror" toggle
            // and a per-app override carry different product semantics. Diagnostics can distinguish.
            let reason: CompletionRenderMode.MirrorReason
            if let bundleIdentifier,
               perAppOverrides[bundleIdentifier] == .alwaysMirror {
                reason = .perAppOverride
            } else {
                reason = .userPreference
            }
            return .mirror(reason: reason)

        case .auto:
            // Only `.estimated` geometry triggers auto-mirror. `.derived` already lands close enough
            // to the real caret to render inline ghost text confidently; promoting it would over-fire
            // the card for hosts that work fine today (Gmail, Outlook, Discord text-marker path).
            // `.layoutEstimated` deliberately falls through to inline as well: it only exists when
            // the caret layout repair accepted a hidden-text-layout estimate, and rendering inline
            // on that estimate is the entire point of the repair.
            return geometry.caretQuality == .estimated
                ? .mirror(reason: .caretGeometryEstimated)
                : .inline
        }
    }
}
