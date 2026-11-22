import Foundation

/// Shortcut choices for one app. A `nil` action inherits its global binding; the disabled-key
/// sentinel remains an explicit override.
struct PerAppShortcutOverride: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    var displayName: String
    var acceptance: SuggestionShortcutBindingSettings?
    var fullAcceptance: SuggestionShortcutBindingSettings?

    var id: String { bundleIdentifier }
}

extension PerAppShortcutOverride {
    /// Apps whose Accept Entire Suggestion binding replaces the global one. A recorded key and
    /// Disable (the disabled-key sentinel) both count; only `nil` inherits the global slot.
    static func bundleIdentifiersOverridingFullAcceptance(in overrides: [PerAppShortcutOverride]) -> Set<String> {
        Set(overrides.filter { $0.fullAcceptance != nil }.map(\.bundleIdentifier))
    }
}
