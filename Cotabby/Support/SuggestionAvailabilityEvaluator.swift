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
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        terminalIntegrationActive: Bool = false,
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

        if let bundleIdentifier = focusSnapshot.bundleIdentifier,
           disabledAppBundleIdentifiers.contains(bundleIdentifier) {
            return "Cotabby is disabled in \(focusSnapshot.applicationName)."
        }

        // Per-site disable: when focus capture resolved a page URL, a host on the user's disabled list
        // (exact or parent domain) suppresses autocomplete the same way a disabled app does. The URL is
        // nil unless the feature is enabled and a browser exposed it, and the list is empty by default,
        // so non-browser focus is unaffected.
        if let urlString = focusSnapshot.context?.focusedURLString,
           let host = BrowserDomain.host(fromURLString: urlString),
           BrowserDomain.isHostDisabled(host, disabledDomains: disabledDomains) {
            return "Cotabby is disabled on \(host)."
        }

        if let terminalReason = terminalDisabledReason(
            focusSnapshot: focusSnapshot,
            isOptedIn: suggestInIntegratedTerminals,
            integrationActive: terminalIntegrationActive
        ) {
            return terminalReason
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
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        terminalIntegrationActive: Bool = false,
        inputMonitoringGranted: Bool,
        focusSnapshot: FocusSnapshot
    ) -> Bool {
        disabledReason(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            terminalIntegrationActive: terminalIntegrationActive,
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
        disabledAppBundleIdentifiers: Set<String> = [],
        disabledDomains: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        terminalIntegrationActive: Bool = false,
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

        // Terminal sources own their own narrow OCR lifecycle. Feeding their pixels through the
        // generic visual-context prompt path would duplicate capture and leak scrollback into the
        // model in addition to the purpose-built shell/TUI context.
        guard focusSnapshot.context?.terminalInputRole == nil else {
            return false
        }

        return disabledReason(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            terminalIntegrationActive: terminalIntegrationActive,
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

    private static func terminalDisabledReason(
        focusSnapshot: FocusSnapshot,
        isOptedIn: Bool,
        integrationActive: Bool
    ) -> String? {
        let hasTerminalRole = focusSnapshot.context?.terminalInputRole != nil
        let isTerminalSurface = TerminalAppDetector.isTerminal(
            bundleIdentifier: focusSnapshot.bundleIdentifier
        ) || focusSnapshot.context?.isIntegratedTerminal == true || hasTerminalRole
        guard isTerminalSurface else { return nil }
        guard isOptedIn else { return "Terminal autocomplete is turned off." }
        // The opt-in is only a master switch. Exact hook data or verified Claude Code OCR must own
        // effective focus before terminal text becomes eligible.
        guard integrationActive, hasTerminalRole else {
            return "Terminal autocomplete is waiting for a live shell or Claude Code source."
        }
        return nil
    }
}
