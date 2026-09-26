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
        temporarilyPaused: Bool = false,
        isLowPowerModeActive: Bool = false,
        isLowPowerModeAutoDisableEnabled: Bool = false,
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        inputMonitoringGranted: Bool,
        focusSnapshot: FocusSnapshot,
        checkCapability: Bool = true
    ) -> String? {
        guard globallyEnabled else {
            return "Cotabby is turned off."
        }

        guard !temporarilyPaused else {
            return "Cotabby is temporarily paused."
        }

        if isLowPowerModeActive && isLowPowerModeAutoDisableEnabled {
            return "Cotabby is paused because Low Power Mode is on."
        }

        if let reason = locationDisabledReason(
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            focusSnapshot: focusSnapshot
        ) {
            return reason
        }

        guard inputMonitoringGranted else {
            return "Input Monitoring permission is required before Cotabby can react to typing."
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
        temporarilyPaused: Bool = false,
        isLowPowerModeActive: Bool = false,
        isLowPowerModeAutoDisableEnabled: Bool = false,
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        inputMonitoringGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> Bool {
        disabledReason(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            isLowPowerModeActive: isLowPowerModeActive,
            isLowPowerModeAutoDisableEnabled: isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            inputMonitoringGranted: inputMonitoringGranted,
            focusSnapshot: focusSnapshot
        ) == nil
    }

    /// Whether the environment allows visual context capture to start.
    ///
    /// Delegates to `disabledReason` with capability checking disabled so transient field
    /// states (text selected, secure field) are intentionally ignored — OCR should start
    /// early in those cases and be ready by the time the user begins typing.
    ///
    /// Two conditions gate capture here and deliberately NOT in `disabledReason`, because both
    /// suppress only the screenshot/OCR pipeline while predictions keep running (they just go out
    /// without visual context):
    /// - Fast mode: the user opted into faster, text-only suggestions.
    /// - Missing Screen Recording permission: the permission is optional, so its absence forces the
    ///   same text-only behavior as fast mode instead of disabling autocomplete.
    static func shouldCaptureVisualContext(
        globallyEnabled: Bool = true,
        temporarilyPaused: Bool = false,
        isLowPowerModeActive: Bool = false,
        isLowPowerModeAutoDisableEnabled: Bool = false,
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot,
        isFastModeEnabled: Bool = false
    ) -> Bool {
        guard !isFastModeEnabled else {
            return false
        }

        guard screenRecordingGranted else {
            return false
        }

        return disabledReason(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            isLowPowerModeActive: isLowPowerModeActive,
            isLowPowerModeAutoDisableEnabled: isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            inputMonitoringGranted: inputMonitoringGranted,
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

    /// Returns the first app, domain, or terminal rule that disables the focused field.
    private static func locationDisabledReason(
        disabledAppBundleIdentifiers: Set<String>,
        disabledDomains: Set<String>,
        suggestInIntegratedTerminals: Bool,
        focusSnapshot: FocusSnapshot
    ) -> String? {
        if let bundleIdentifier = focusSnapshot.bundleIdentifier,
           disabledAppBundleIdentifiers.contains(bundleIdentifier) {
            return "Cotabby is disabled in \(focusSnapshot.applicationName)."
        }

        // Only focus snapshots with a resolved browser URL can match disabled domains.
        if let urlString = focusSnapshot.context?.focusedURLString,
           let host = BrowserDomain.host(fromURLString: urlString),
           BrowserDomain.isHostDisabled(host, disabledDomains: disabledDomains) {
            return "Cotabby is disabled on \(host)."
        }

        if TerminalAppDetector.isTerminal(bundleIdentifier: focusSnapshot.bundleIdentifier) {
            return "Cotabby is not available in terminal apps."
        }

        // Integrated terminals share the editor's bundle ID, so check their AX-derived flag.
        if !suggestInIntegratedTerminals, focusSnapshot.context?.isIntegratedTerminal == true {
            return "Cotabby is not available in the integrated terminal."
        }

        return nil
    }
}
