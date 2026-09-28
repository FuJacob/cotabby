import Foundation

/// User-facing preference for how Cotabby presents completions.
///
/// `auto` defers to caret-geometry quality: trustworthy geometry stays inline, weak geometry promotes
/// to mirror mode. `alwaysInline` and `alwaysMirror` let power users pin a strategy when the
/// auto rule misfires for their host mix.
///
/// The global preference is live (Appearance settings Picker); per-app overrides are not wired yet.
/// Note that under `auto` a mid-line caret promotes inline to the card; see
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
        let preferred = preferenceMode(for: geometry, bundleIdentifier: bundleIdentifier)
        // Text after the caret on its own line is the host's, and an inline ghost there can only
        // sit on top of it. Painting the ghost over an opaque band in the field's background color
        // was tried (2026-09-10) and read as the suggestion overwriting the user's text, so a
        // mid-line caret gets the card anchored under it instead; the card is a preview, not a
        // forgery, and leaves the host's own characters alone. `alwaysInline` is an explicit
        // request and keeps its inline pick; the controller still declines to paint over text.
        if case .inline = preferred, !geometry.isCaretAtEndOfLine, effectivePreference(for: bundleIdentifier) != .alwaysInline {
            return .mirror(reason: .caretMidLine)
        }
        return preferred
    }

    private func effectivePreference(for bundleIdentifier: String?) -> MirrorPreference {
        if let bundleIdentifier, let override = perAppOverrides[bundleIdentifier] {
            return override
        }
        return userPreference
    }

    /// The render mode implied by the user (or per-app) preference and caret-geometry quality, before
    /// the mid-line rule in `mode(for:bundleIdentifier:)` is applied. Split out so that rule reads
    /// as a single, well-scoped statement rather than another branch threaded through the switch.
    private func preferenceMode(
        for geometry: SuggestionOverlayGeometry,
        bundleIdentifier: String?
    ) -> CompletionRenderMode {
        switch effectivePreference(for: bundleIdentifier) {
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
            // `.derived` and `.exact` land close enough to the real caret to render inline ghost
            // text confidently; promoting them would over-fire the card for hosts that work fine
            // today (Gmail, Outlook, Discord text-marker path).
            //
            // Both estimate qualities go to the card. `.estimated` is not precise enough to paint
            // inline glyphs, but its vertical line box is useful for popup placement: the AXFrame
            // fallback centers single-line text and bottom-aligns multiline text. `.layoutEstimated`
            // means the hidden-TextKit repair produced a more confident caret estimate. It still uses
            // a card because that estimate is good enough to place a popup, not to paint glyphs the
            // eye will scrutinize against the host's own text.
            switch geometry.caretQuality {
            case .estimated:
                return .mirror(reason: .caretGeometryEstimated)
            case .layoutEstimated:
                return .mirror(reason: .caretLayoutEstimated)
            case .exact, .derived:
                return .inline
            }
        }
    }
}
