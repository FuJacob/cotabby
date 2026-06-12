import Foundation

/// File overview:
/// Reads the per-site disable configuration from UserDefaults: a default-off feature flag and the
/// user's list of disabled domains. Kept as a thin, injectable reader so the matching logic
/// (`BrowserDomain`) and the gate (`SuggestionAvailabilityEvaluator`) stay pure, and so the feature
/// is configurable via `defaults write` while it has no settings UI yet — the same hidden-flag
/// pattern the experimental decoder paths use.
enum PerDomainDisableSettings {
    /// Turns on per-site disable, *including* the Accessibility URL read in focus capture. Default-off
    /// so the focus-capture hot path is untouched until a dogfooder opts in and validates the URL read
    /// on device.
    static let enabledKey = "cotabbyPerDomainDisableEnabled"
    /// Holds the disabled-domain entries (an array of strings; bare hosts or full URLs both work).
    static let disabledDomainsKey = "cotabbyDisabledDomains"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The configured disabled-domain entries while the feature flag is on, or an empty set
    /// otherwise. The flag gate lives here (not only in the evaluator) because this is read on
    /// every keystroke's availability check; with the default-off flag, paying a defaults array
    /// read plus `Set` construction per key would be pure waste, and the gate is inert anyway
    /// since focus capture only reads page URLs while the flag is on.
    static func disabledDomains(_ defaults: UserDefaults = .standard) -> Set<String> {
        guard isEnabled(defaults) else {
            return []
        }
        guard let entries = defaults.stringArray(forKey: disabledDomainsKey) else {
            return []
        }
        return Set(entries)
    }
}
