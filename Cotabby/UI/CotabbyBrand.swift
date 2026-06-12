import SwiftUI

/// File overview:
/// Cotabby's brand palette, shared by every surface that speaks in the brand voice (onboarding,
/// the permission reminder, and the Settings Home hero). Pinned rather than derived from
/// `Color.accentColor` so brand moments stay on-brand even when the user picks a different system
/// accent; ordinary interactive controls should keep following the system accent.
enum CotabbyBrand {
    /// The brand blue, sampled from the app icon's background (#007AFF). Identical in both
    /// appearances.
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)

    /// Lighter companion to `accent`, used as the top stop of icon-tile and pip gradients so
    /// tinted elements read as lit from above (the System Settings icon treatment).
    static let accentSoft = Color(red: 0.33, green: 0.63, blue: 1.0)
}
