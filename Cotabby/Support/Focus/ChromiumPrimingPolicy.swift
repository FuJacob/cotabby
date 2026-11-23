import Foundation

/// The decisions behind `ChromiumAccessibilityEnabler`, kept free of Accessibility writes so they
/// can be unit tested: whether a process should be primed on this poll, and which fallbacks to try
/// when it rejects `AXManualAccessibility`.
nonisolated enum ChromiumPrimingPolicy {
    /// What is known about one process. A process that was never primed has no entry.
    enum ProcessState: Equatable, Sendable {
        /// A priming write was accepted. Throttles priming to once per process (and once per
        /// activation for Electron editors) so the per-tick call is a cheap lookup.
        case primed
        /// Every way of priming was rejected as unsupported; retrying each tick would be a doomed
        /// cross-process write.
        case unsupported
    }

    /// A way to wake the web accessibility tree once `AXManualAccessibility` is unsupported.
    enum Fallback: Equatable, Sendable {
        /// `AXEnhancedUserInterface`, trusting a successful write.
        case enhancedUserInterface
        /// `AXEnhancedUserInterface`, believing only the value read back afterwards.
        case enhancedUserInterfaceConfirmedByReadBack
    }

    /// Whether to send the `AXManualAccessibility` write this poll.
    ///
    /// Electron editors are re-primed on every activation edge (each time the app becomes
    /// frontmost), not just once per process. Observed on VS Code: the first write returns success
    /// while the app is long-running, yet the web-AX tree stays dormant for minutes; a later
    /// re-assert wakes it promptly. One extra AX write per app switch is negligible, and Chromium
    /// browsers keep the once-per-process behavior that already works for them.
    static func shouldPrime(state: ProcessState?, isActivationEdge: Bool, isElectronEditor: Bool) -> Bool {
        switch state {
        case .unsupported:
            return false
        case .primed:
            return isActivationEdge && isElectronEditor
        case nil:
            return true
        }
    }

    /// The fallbacks to try, in order, for an app that rejected `AXManualAccessibility`. Empty
    /// means the process is simply unsupported.
    ///
    /// - Chrome itself rejects `AXManualAccessibility` (an Electron addition). Its full
    ///   accessibility mode, the one that computes inline text boxes so character bounds and font
    ///   attributes exist, is switched on by the VoiceOver signal instead. The user's kill switch
    ///   turns this off, because some window managers misplace windows of apps that have it set.
    /// - Codex embeds Chromium in a native shell that also rejects it; the same switch exposes the
    ///   composed web tree there. That shell can report an error after applying the value, so only
    ///   a read-back says whether it took. Kept specific to Codex: setting the flag on arbitrary
    ///   apps is what affects window managers.
    static func fallbacksAfterManualAccessibilityUnsupported(
        isChromiumBrowser: Bool,
        isCodexDesktop: Bool,
        isEnhancedUserInterfaceDisabled: Bool
    ) -> [Fallback] {
        var fallbacks: [Fallback] = []
        if isChromiumBrowser, !isEnhancedUserInterfaceDisabled {
            fallbacks.append(.enhancedUserInterface)
        }
        if isCodexDesktop {
            fallbacks.append(.enhancedUserInterfaceConfirmedByReadBack)
        }
        return fallbacks
    }
}
