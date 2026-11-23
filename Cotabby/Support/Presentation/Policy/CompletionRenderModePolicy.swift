import Foundation

/// User-facing preference for how Cotabby presents completions.
///
/// `auto` defers to caret-geometry quality: trustworthy geometry stays inline, weak geometry promotes
/// to mirror mode. `alwaysInline` and `alwaysMirror` let power users pin a strategy when the
/// auto rule misfires for their host mix.
///
/// The preference is global (Appearance settings Picker and the menu bar). Note that under `auto`
/// a mid-line caret promotes inline to the card; see `CompletionRenderModePolicy.mode(for:)`.
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
/// and makes the rule trivially unit-testable. Adding a new trigger means editing this one struct
/// rather than threading conditionals through the controller.
///
/// `Sendable` because the policy is a pure value type built from `Sendable` members; the explicit
/// `nonisolated init` keeps it constructible off the main actor under the module's default
/// main-actor isolation.
struct CompletionRenderModePolicy: Equatable, Sendable {
    let userPreference: MirrorPreference

    nonisolated init(userPreference: MirrorPreference = .auto) {
        self.userPreference = userPreference
    }

    /// Decides which render mode to use for one presentation.
    func mode(for geometry: SuggestionOverlayGeometry) -> CompletionRenderMode {
        let preferred = preferenceMode(for: geometry)
        // Text after the caret on its own line is the host's, and an inline ghost there can only
        // sit on top of it. Painting the ghost over an opaque band in the field's background color
        // was tried (2026-09-10) and read as the suggestion overwriting the user's text, so a
        // mid-line caret gets the card anchored under it instead; the card is a preview, not a
        // forgery, and leaves the host's own characters alone. `alwaysInline` is an explicit
        // request and keeps its inline pick; the controller still declines to paint over text.
        if case .inline = preferred, !geometry.isCaretAtEndOfLine, userPreference != .alwaysInline {
            return .mirror(reason: .caretMidLine)
        }
        return preferred
    }

    /// The render mode implied by the user's preference and caret-geometry quality, before the
    /// mid-line rule in `mode(for:)` is applied. Split out so that rule reads as a single,
    /// well-scoped statement rather than another branch threaded through the switch.
    private func preferenceMode(for geometry: SuggestionOverlayGeometry) -> CompletionRenderMode {
        switch userPreference {
        case .alwaysInline:
            return .inline

        case .alwaysMirror:
            return .mirror(reason: .userPreference)

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
