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
        disabledDomains: Set<String> = [],
        focusedURLString: String? = nil,
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

        // Per-site disable: when the focused element carries a web URL, a host on the user's disabled
        // list (exact or parent domain) suppresses autocomplete the same way a disabled app does.
        // Defaults make this inert (no URL / empty list) so non-browser focus is unaffected.
        if let focusedURLString,
           let host = BrowserDomain.host(fromURLString: focusedURLString),
           BrowserDomain.isHostDisabled(host, disabledDomains: disabledDomains) {
            return "Cotabby is disabled on \(host)."
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
    ///
    /// Fast mode is checked here, and deliberately NOT in `disabledReason`: it suppresses only the
    /// screenshot/OCR pipeline. Predictions still run (they just go out without visual context), so
    /// `disabledReason` / `shouldSchedulePrediction` must stay unaffected.
    static func shouldCaptureVisualContext(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot,
        isFastModeEnabled: Bool = false
    ) -> Bool {
        guard !isFastModeEnabled else {
            return false
        }

        return disabledReason(
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
