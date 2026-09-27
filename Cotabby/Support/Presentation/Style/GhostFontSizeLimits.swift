import CoreGraphics

/// File overview:
/// The shared legibility backstop for ghost text, and the rule that applies the user's own size
/// limits (Settings → Appearance → Ghost Text Size Limits) on top of whatever size the host's font
/// resolution produced.
///
/// Why this is its own type: two presentation paths size the ghost independently. The inline path
/// resolves the host's face and size from Accessibility, pixels, and caret advances
/// (`GhostFontResolver` and `OverlayController`), while the card path uses a fixed size scaled by the
/// user's multiplier (`MirrorOverlayLayout`). Both must honor the same floor, and the settings model
/// pins its slider minimum to it, so the number lives in one pure, dependency-free place rather than
/// being restated in each.
nonisolated enum GhostFontSizeLimits {
    /// Below this the ghost is unreadable on any display, whatever the host reports or the user sets.
    static let absoluteMinimumPointSize: CGFloat = 9

    /// `size` held inside the user's floor and ceiling, with the legibility backstop applied last.
    ///
    /// The floor and ceiling are absolute: they express what the user is willing to read, so they
    /// win over any size the host's own metrics suggested. An inverted range (floor above ceiling)
    /// cannot be persisted by the settings model, but if it ever arrives the ceiling is applied
    /// first so the floor still wins, matching the model's documented intent.
    static func clamped(_ size: CGFloat, floor: CGFloat, ceiling: CGFloat) -> CGFloat {
        var clamped = size
        if ceiling > 0 { clamped = min(clamped, ceiling) }
        if floor > 0 { clamped = max(clamped, floor) }
        return max(absoluteMinimumPointSize, clamped)
    }
}
