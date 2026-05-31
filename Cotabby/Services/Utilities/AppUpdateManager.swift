import Combine
import Foundation
import Logging
import Sparkle

/// File overview:
/// Owns Cotabby's Sparkle integration and keeps updater lifecycle out of SwiftUI views.
/// This is a classic service-layer boundary in the app's architecture: Sparkle is a side-effectful
/// framework that talks to the network, persists updater preferences, and may present system UI.
///
/// We keep it in `Services/` so the rest of the app only depends on a tiny, explicit surface:
/// `start()` for lifecycle wiring and `checkForUpdates()` for a future settings screen.
@MainActor
final class AppUpdateManager: ObservableObject {
    /// The updater is created once and retained for the lifetime of the process, just like the
    /// runtime manager and the focus tracker. Sparkle expects its controller to stay alive.
    private let updaterController: SPUStandardUpdaterController

    private var isStarted = false

    private static let debugCheckForUpdatesOnLaunchArgument = "-Cotabby-check-for-updates-on-launch"
    private static let publicKeyPlaceholder = "REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY"

    init() {
        // `startingUpdater: false` keeps lifecycle explicit. The app delegate decides when the
        // updater starts instead of Sparkle implicitly doing work during dependency construction.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Starts Sparkle exactly once after app launch.
    /// We validate the minimal required Info.plist settings first so a development build with the
    /// placeholder public key does not trigger Sparkle's "app is misconfigured" alert.
    func start() {
        guard !isStarted else {
            return
        }

        guard hasUsableConfiguration else {
            log("Sparkle not started because updater configuration is incomplete.")
            return
        }

        updaterController.startUpdater()
        isStarted = true
        log("Sparkle updater started.")

        // Check once on every launch. Sparkle's scheduled check only fires on launch when the
        // interval has already elapsed, so frequent users (who reopen within a day) would never
        // see a check on open. This is a *background* check: it silently does nothing when the app
        // is up to date and only surfaces UI when an update is actually available — unlike
        // `checkForUpdates()`, which always shows a result dialog and is reserved for the manual
        // "Check for Updates" button. The daily `SUScheduledCheckInterval` then covers long-running
        // sessions where the app stays open for days.
        // Respect the user's "Automatically check for updates" preference: when they have turned
        // automatic checks off, skip even this launch check so the toggle fully governs background
        // update activity. Sparkle's daily scheduled check already honors the same flag.
        if automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        } else {
            log("Skipping launch update check because automatic checks are disabled.")
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.debugCheckForUpdatesOnLaunchArgument) {
            log("Debug launch argument requested an immediate update check.")
            checkForUpdates()
        }
        #endif
    }

    /// Future UI surfaces, such as Settings, should call this method instead of touching Sparkle
    /// directly. That keeps the rest of the codebase decoupled from Sparkle APIs.
    func checkForUpdates() {
        guard isStarted else {
            log("Ignoring manual update check because the updater has not started.")
            return
        }

        updaterController.checkForUpdates(nil)
    }

    /// Whether Sparkle performs automatic update checks: the once-per-launch background check in
    /// `start()` and Sparkle's daily scheduled check. This proxies Sparkle's own persisted
    /// preference (`SUEnableAutomaticChecks`, defaulted to `true` in Info.plist) instead of storing a
    /// second copy, so the Settings toggle and the updater can never disagree. The setter notifies
    /// SwiftUI observers so a bound toggle re-renders, and Sparkle persists the value for next launch.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            guard newValue != updaterController.updater.automaticallyChecksForUpdates else {
                return
            }
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
            log("Automatic update checks \(newValue ? "enabled" : "disabled") by user preference.")
        }
    }

    private var hasUsableConfiguration: Bool {
        guard let feedURLString = configuredString(forInfoDictionaryKey: "SUFeedURL"),
              URL(string: feedURLString) != nil
        else {
            log("Missing or invalid SUFeedURL.")
            return false
        }

        guard let publicKey = configuredString(forInfoDictionaryKey: "SUPublicEDKey"),
              publicKey != Self.publicKeyPlaceholder
        else {
            log("SUPublicEDKey is missing or still using the placeholder value.")
            return false
        }

        return true
    }

    private func configuredString(forInfoDictionaryKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func log(_ message: String) {
        CotabbyLogger.updates.info("\(message)")
    }
}
