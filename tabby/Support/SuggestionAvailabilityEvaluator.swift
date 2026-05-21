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
        interactionMode: SuggestionInteractionMode = .autocomplete,
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

        guard inputMonitoringGranted else {
            return "Input Monitoring permission is required before Tabby can react to typing."
        }

        if interactionMode == .autocomplete {
            guard screenRecordingGranted else {
                return "Screen Recording permission is required before Tabby can build visual context "
                    + "for autocomplete."
            }
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
        interactionMode: SuggestionInteractionMode = .autocomplete,
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> Bool {
        disabledReason(
            globallyEnabled: globallyEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            interactionMode: interactionMode,
            inputMonitoringGranted: inputMonitoringGranted,
            screenRecordingGranted: screenRecordingGranted,
            focusSnapshot: focusSnapshot
        ) == nil
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
