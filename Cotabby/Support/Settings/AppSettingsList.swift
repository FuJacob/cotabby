import Foundation

/// One row of the Apps settings list.
struct AppSettingsEntry: Equatable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    /// Typing-history entries collected in this app.
    let inputCount: Int
    let isDisabled: Bool
    /// The app has its own keys or behavior instead of following every global setting.
    let hasOverrides: Bool
    let isExcludedFromHistory: Bool

    var id: String { bundleIdentifier }
}

/// Builds the Apps settings list from the stores that each own part of an app's configuration.
///
/// An app is listed when anything is known about it: typing history was collected there, it is
/// disabled, it has per-app overrides, it is excluded from history, or the user just added it.
/// Pure so the merge and ordering rules are tested without any AppKit lookups; display names for
/// apps only known by bundle identifier come from the injected `displayName` closure.
enum AppSettingsList {
    static func entries(
        inputCounts: [String: Int],
        disabledRules: [DisabledApplicationRule],
        overrides: [PerAppShortcutOverride],
        excludedFromHistory: [String],
        addedBundleIdentifiers: [String] = [],
        displayName: (String) -> String
    ) -> [AppSettingsEntry] {
        var names: [String: String] = [:]
        for rule in disabledRules { names[rule.bundleIdentifier] = rule.displayName }
        for override in overrides { names[override.bundleIdentifier] = override.displayName }

        let disabled = Set(disabledRules.map { $0.bundleIdentifier })
        let customizedOverrides = overrides.filter { override in
            override.acceptance != nil || override.fullAcceptance != nil || override.behavior != nil
        }
        let customized = Set(customizedOverrides.map { $0.bundleIdentifier })
        let excluded = Set(excludedFromHistory)
        var identifiers = Set(inputCounts.keys)
        identifiers.formUnion(disabled)
        identifiers.formUnion(overrides.map { $0.bundleIdentifier })
        identifiers.formUnion(excluded)
        identifiers.formUnion(addedBundleIdentifiers)
        // Imported rows with no app recorded carry a placeholder; there is no app to configure.
        // Older imports stored Cotypist's own "unknown.bundle" before the importer normalized it.
        identifiers.remove(CotypistExportImporter.unknownBundleIdentifier)
        identifiers.remove("unknown.bundle")

        return identifiers.map { identifier in
            AppSettingsEntry(
                bundleIdentifier: identifier,
                displayName: names[identifier] ?? displayName(identifier),
                inputCount: inputCounts[identifier] ?? 0,
                isDisabled: disabled.contains(identifier),
                hasOverrides: customized.contains(identifier),
                isExcludedFromHistory: excluded.contains(identifier)
            )
        }
        .sorted {
            // Most-used first, like the list users know from other autocomplete apps; ties by name.
            if $0.inputCount != $1.inputCount { return $0.inputCount > $1.inputCount }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Case-insensitive match on name or bundle identifier for the list's search field.
    static func filter(_ entries: [AppSettingsEntry], query: String) -> [AppSettingsEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
