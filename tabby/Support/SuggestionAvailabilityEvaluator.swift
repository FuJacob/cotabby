import Foundation

/// File overview:
/// Centralizes the repeated gating rules that decide whether Tabby can react to the current focus
/// and whether a refreshed prediction is worthwhile. This is intentionally pure and deterministic.
///
/// The value of this helper is consistency: permission/focus checks appear in several coordinator
/// paths, and moving them here prevents small wording or branching differences from creeping in.
enum SuggestionAvailabilityEvaluator {
    static func disabledReason(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> String? {
        guard globallyEnabled else {
            return "Tabby is turned off."
        }

        if let bundleIdentifier = focusSnapshot.bundleIdentifier,
           disabledAppBundleIdentifiers.contains(bundleIdentifier) {
            return "Tabby is disabled in \(focusSnapshot.applicationName)."
        }

        if TerminalAppDetector.isTerminal(bundleIdentifier: focusSnapshot.bundleIdentifier) {
            return "Tabby is not available in terminal apps."
        }

        guard inputMonitoringGranted else {
            return "Input Monitoring permission is required before Tabby can react to typing."
        }

        guard screenRecordingGranted else {
            return "Screen Recording permission is required before Tabby can build visual context "
                + "for autocomplete."
        }

        switch focusSnapshot.capability {
        case .supported:
            return nil
        case let .blocked(reason), let .unsupported(reason):
            return reason
        }
    }

    static func shouldSchedulePrediction(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> Bool {
        disabledReason(
            globallyEnabled: globallyEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            inputMonitoringGranted: inputMonitoringGranted,
            screenRecordingGranted: screenRecordingGranted,
            focusSnapshot: focusSnapshot
        ) == nil
    }

    /// Whether the environment allows visual context capture to start.
    ///
    /// Unlike `disabledReason`, this ignores transient field-level states (text selected,
    /// secure field) so the OCR pipeline can start early and be ready by the time the user
    /// types. Returns `false` only for hard environment disables: globally off, per-app
    /// disabled, terminal apps, and missing permissions.
    static func shouldCaptureVisualContext(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> Bool {
        guard globallyEnabled else { return false }

        if let bundleIdentifier = focusSnapshot.bundleIdentifier,
           disabledAppBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }

        if TerminalAppDetector.isTerminal(bundleIdentifier: focusSnapshot.bundleIdentifier) {
            return false
        }

        guard inputMonitoringGranted else { return false }
        guard screenRecordingGranted else { return false }

        return true
    }

    static func shouldSchedulePredictionWhenVisualContextBecomesReady(
        focusSnapshot: FocusSnapshot,
        matching identity: FocusedInputIdentity
    ) -> Bool {
        guard case .supported = focusSnapshot.capability,
              let context = focusSnapshot.context,
              context.identity == identity
        else {
            return false
        }

        return SuggestionRequestFactory.shouldGenerateSuggestion(for: context.precedingText)
    }
}
