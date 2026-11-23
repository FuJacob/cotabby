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

    /// Whether the environment allows visual context capture to start.
    ///
    /// Delegates to `disabledReason` with capability checking disabled so transient field
    /// states (text selected, caret bounds momentarily missing) are intentionally ignored — OCR
    /// should start early in those cases and be ready by the time the user begins typing. Blocks
    /// that describe the field itself are not transient and do stop capture
    /// (`excludesFieldFromVisualContext`).
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

        guard !excludesFieldFromVisualContext(focusSnapshot) else {
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

    /// Whether the focused field must not be screenshotted at all, even where capture is otherwise
    /// allowed: a secure field, a sign-in or verification field (email, one-time code, card number),
    /// one of Mail's address or subject rows, or a search box.
    ///
    /// Suggestions never run in these fields, and an excerpt only serves the field it was captured
    /// for, so a capture there feeds no prompt. For the first two it would still copy what the user
    /// is typing (a card number, a code, an address) into OCR text held in memory; for the others it
    /// only costs a screenshot and OCR every few seconds. "Text is selected" and missing AX data are
    /// not listed: they pass within the same field, whose context should stay warm.
    static func excludesFieldFromVisualContext(_ focusSnapshot: FocusSnapshot) -> Bool {
        if focusSnapshot.context?.isSecure == true {
            return true
        }
        guard case let .blocked(reason) = focusSnapshot.capability else {
            return false
        }
        // The detectors' own reason constants, which the resolver publishes verbatim: these blocks
        // describe what the field is, so they hold for as long as focus stays there.
        return [
            CredentialFieldDetector.blockedReason,
            MailHeaderFieldDetector.blockedReason,
            SearchFieldDetector.blockedReason
        ].contains(reason)
    }

    /// Whether a prediction teardown should leave the focused field's visual-context session alive.
    ///
    /// Predictions stop for transient states of a field the user is still in: ⌘A in a chat composer
    /// publishes "Text is currently selected." until the next keystroke replaces the selection. The
    /// screen context belongs to the field, not to one prediction cycle, so tearing it down there
    /// cost a fresh screenshot and OCR on that keystroke and changed the prompt head. It survives
    /// only when `disabledReason` is the field's own capability state and capture would still be
    /// allowed for it; a missing or secure field and every environment reason (off, paused,
    /// disabled app or site, permissions, fast mode) end it.
    static func shouldKeepVisualContextWhileDisabled(
        disabledReason: String,
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
        switch focusSnapshot.capability {
        case .supported:
            return false
        case let .blocked(reason), let .unsupported(reason):
            guard reason == disabledReason else { return false }
        }
        guard let context = focusSnapshot.context, !context.isSecure else {
            return false
        }

        return shouldCaptureVisualContext(
            globallyEnabled: globallyEnabled,
            temporarilyPaused: temporarilyPaused,
            isLowPowerModeActive: isLowPowerModeActive,
            isLowPowerModeAutoDisableEnabled: isLowPowerModeAutoDisableEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            disabledDomains: disabledDomains,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            inputMonitoringGranted: inputMonitoringGranted,
            screenRecordingGranted: screenRecordingGranted,
            focusSnapshot: focusSnapshot,
            isFastModeEnabled: isFastModeEnabled
        )
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

        return SuggestionRequestFactory.shouldGenerateSuggestion(
            for: context.precedingText, trailingText: context.trailingText
        )
    }

    /// How long after an accept a changed screen-context excerpt may not retire the suggestion. 500 ms
    /// covers the gap between Tab presses in a normal accept burst (measured 150-370 ms in a Gmail
    /// repro) without keeping a stale tail much past it. A fixed policy rather than a setting: it is a
    /// timing detail of the accept pipeline, not a preference users can reason about.
    static let postAcceptHoldMilliseconds = 500

    /// How many milliseconds a changed screen-context excerpt must wait before it may retire the
    /// suggestion, because the user accepted within the last `holdMilliseconds`. 0 means act now.
    ///
    /// A changed excerpt normally retires the visible tail and regenerates: on a host that exposes
    /// identical field identity for two conversations, it is the only navigation signal. But
    /// accepting words changes the screen too, so the ~3s OCR refresh read a Tab burst as navigation
    /// and replaced the suggestion between presses (and the next Tab, finding no ghost or armed
    /// post-exhaustion window, reached the host). The caller defers the retirement by the returned
    /// amount instead of dropping it, so a real navigation is still acted on once accepting stops.
    ///
    /// Both instants are `ProcessInfo.systemUptime` seconds: a wall-clock step backwards would
    /// otherwise make the elapsed time negative and hold the navigation signal for that long.
    static func postAcceptanceHoldRemainingMilliseconds(
        lastAcceptanceUptime: TimeInterval?,
        nowUptime: TimeInterval,
        holdMilliseconds: Int
    ) -> Int {
        guard let lastAcceptanceUptime, holdMilliseconds > 0 else { return 0 }
        let elapsedMilliseconds = Int(((nowUptime - lastAcceptanceUptime) * 1_000).rounded(.down))
        return max(0, holdMilliseconds - max(0, elapsedMilliseconds))
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
