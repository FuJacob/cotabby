import Foundation

/// Per-app overrides for one app: accept keys and suggestion behavior. A `nil` action inherits its
/// global binding; the disabled-key sentinel remains an explicit override. The type keeps its
/// original name because its JSON is persisted under `cotabbyPerAppShortcutOverrides`.
struct PerAppShortcutOverride: Codable, Equatable, Identifiable, Sendable {
    let bundleIdentifier: String
    var displayName: String
    var acceptance: SuggestionShortcutBindingSettings?
    var fullAcceptance: SuggestionShortcutBindingSettings?
    /// App-specific suggestion behavior (mid-line, autocorrect, instructions). Optional so records
    /// saved before this existed decode unchanged; nil means every behavior follows the global setting.
    var behavior: PerAppBehavior?

    var id: String { bundleIdentifier }
}
