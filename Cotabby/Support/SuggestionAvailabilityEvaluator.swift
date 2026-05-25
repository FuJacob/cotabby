import Foundation

/// File overview:
/// Centralizes the repeated gating rules that decide whether Cotabby can react to the current focus
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
        focusSnapshot: FocusSnapshot,
        checkCapability: Bool = true
    ) -> String? {
        guard globallyEnabled else {
            return "Cotabby is turned off."
        }

        if let bundleIdentifier = focusSnapshot.bundleIdentifier,
           disabledAppBundleIdentifiers.contains(bundleIdentifier) {
            return "Cotabby is disabled in \(focusSnapshot.applicationName)."
        }

        if TerminalAppDetector.isTerminal(bundleIdentifier: focusSnapshot.bundleIdentifier) {
            return "Cotabby is not available in terminal apps."
        }

        guard inputMonitoringGranted else {
            return "Input Monitoring permission is required before Cotabby can react to typing."
        }

        guard screenRecordingGranted else {
            return "Screen Recording permission is required before Cotabby can build visual context "
                + "for autocomplete."
        }

        guard checkCapability else {
            return nil
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
    /// Delegates to `disabledReason` with capability checking disabled so transient field
    /// states (text selected, secure field) are intentionally ignored — OCR should start
    /// early in those cases and be ready by the time the user begins typing.
    static func shouldCaptureVisualContext(
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
            focusSnapshot: focusSnapshot,
            checkCapability: false
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
