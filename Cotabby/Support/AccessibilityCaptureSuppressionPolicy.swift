import Foundation

/// One built-in Accessibility capture safeguard surfaced in Settings.
///
/// This is metadata, not persisted state. The policy owns the default because it also owns the
/// compatibility rule; `SuggestionSettingsModel` only persists user overrides that opt back into
/// capture for one of these bundle identifiers.
struct AccessibilityCaptureSuppressedApplication: Equatable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let reason: String

    var id: String { bundleIdentifier }
}

/// File overview:
/// Centralizes app-level exceptions where Cotabby must not inspect the focused Accessibility tree.
///
/// Most app compatibility rules should live in the normal availability pipeline so users can still
/// choose where Cotabby runs. This policy is narrower: it protects host apps whose transient UI is
/// destabilized by AX attribute enumeration itself. The caller should consult it before any deep
/// candidate walk, because once that walk starts the host popover may already have closed. Users
/// can still opt back into capture per app through Settings; the default remains conservative.
enum AccessibilityCaptureSuppressionPolicy {
    /// Apps whose focused AX tree is not safe to enumerate continuously.
    ///
    /// Apple Calendar's event-detail popover can dismiss itself when Cotabby polls text capability
    /// on its temporary editor hierarchy. Suppressing capture at the app boundary is conservative,
    /// but the metadata is public inside the app so Settings can show the user the tradeoff and let
    /// them opt back in deliberately.
    static let suppressedApplications: [AccessibilityCaptureSuppressedApplication] = [
        AccessibilityCaptureSuppressedApplication(
            bundleIdentifier: "com.apple.iCal",
            displayName: "Calendar",
            reason: "Event editor popovers can close when helper apps inspect their Accessibility tree."
        )
    ]

    private static let suppressedBundleIdentifiers = Set(suppressedApplications.map(\.bundleIdentifier))

    /// Returns true when focus polling should stop after the cheap focused-element query and before
    /// `FocusSnapshotResolver` performs AX candidate enumeration.
    static func shouldSuppressCapture(
        bundleIdentifier: String?,
        overrideBundleIdentifiers: Set<String> = []
    ) -> Bool {
        guard let bundleIdentifier = SuggestionSettingsStore.normalizedBundleIdentifier(bundleIdentifier) else {
            return false
        }

        let normalizedOverrides = SuggestionSettingsStore.sanitizedBundleIdentifierSet(
            Array(overrideBundleIdentifiers)
        )
        return suppressedBundleIdentifiers.contains(bundleIdentifier)
            && !normalizedOverrides.contains(bundleIdentifier)
    }
}
