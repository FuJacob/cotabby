import Foundation

/// File overview:
/// The curated set of ghost-text colors offered in Settings.
///
/// Why this file exists:
/// Users asked to recolor the inline suggestion, but a free `ColorPicker` makes it easy to land on
/// illegible or jarring colors. Exposing a small fixed palette keeps every choice readable against
/// real editors while still satisfying the request. Each preset is just the hex string the settings
/// model already persists (`nil` for the adaptive "Automatic" gray the overlay falls back to), so no
/// new persistence format is introduced.
struct GhostTextColorPreset: Identifiable, Equatable {
    let id: String
    let name: String
    /// Persisted hex (uppercased, 6 digits), or `nil` for the adaptive automatic gray.
    let hex: String?

    static let automatic = GhostTextColorPreset(id: "automatic", name: "Automatic", hex: nil)

    /// Automatic plus five distinct accent hues. Order is the swatch order shown in Settings.
    static let all: [GhostTextColorPreset] = [
        automatic,
        GhostTextColorPreset(id: "blue", name: "Blue", hex: "3B82F6"),
        GhostTextColorPreset(id: "green", name: "Green", hex: "22C55E"),
        GhostTextColorPreset(id: "purple", name: "Purple", hex: "A855F7"),
        GhostTextColorPreset(id: "orange", name: "Orange", hex: "F97316"),
        GhostTextColorPreset(id: "pink", name: "Pink", hex: "EC4899")
    ]

    /// Matches a persisted hex back to its preset so the UI can highlight the active swatch. Falls
    /// back to `automatic` when the stored value is absent or no longer in the palette.
    static func matching(hex: String?) -> GhostTextColorPreset {
        guard let hex else {
            return automatic
        }

        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return all.first { $0.hex?.uppercased() == normalized } ?? automatic
    }
}
