import Foundation

/// File overview:
/// Centralizes app-level exceptions where Cotabby must not inspect the focused Accessibility tree.
///
/// Most app compatibility rules should live in the normal availability pipeline so users can still
/// choose where Cotabby runs. This policy is narrower: it protects host apps whose transient UI is
/// destabilized by AX attribute enumeration itself. The caller should consult it before any deep
/// candidate walk, because once that walk starts the host popover may already have closed.
enum AccessibilityCaptureSuppressionPolicy {
    /// Bundle identifiers whose focused AX tree is not safe to enumerate continuously.
    ///
    /// Apple Calendar's event-detail popover can dismiss itself when Cotabby polls text capability
    /// on its temporary editor hierarchy. Suppressing capture at the app boundary is conservative,
    /// but it keeps Calendar's own editing controls usable while leaving keyboard monitoring and the
    /// rest of Cotabby untouched.
    private static let unsafeBundleIdentifiers: Set<String> = [
        "com.apple.iCal"
    ]

    /// Returns true when focus polling should stop after the cheap focused-element query and before
    /// `FocusSnapshotResolver` performs AX candidate enumeration.
    static func shouldSuppressCapture(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return unsafeBundleIdentifiers.contains(bundleIdentifier)
    }
}
