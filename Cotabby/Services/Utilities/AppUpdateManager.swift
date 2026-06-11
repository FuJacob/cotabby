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
final class AppUpdateManager {
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

        guard Self.isUpdaterEnabledForThisBuild else {
            // Dev builds carry a distinct bundle identifier (`com.jacobfu.tabby.dev`) so they hold
            // their own Accessibility/TCC grant, independent of the released app. Sparkle must never
            // run here: the prod appcast points at the Developer ID-signed release, and letting it
            // install would swap that bundle in over the dev app, collapsing the separate identity
            // this build exists to preserve.
            log("Sparkle disabled for dev build.")
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
        updaterController.updater.checkForUpdatesInBackground()

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

    /// Whether Sparkle should run for this build. Compiled out to `false` in the dev configuration
    /// (the `COTABBY_DEV` flag), which ships under a distinct bundle identifier that the prod appcast
    /// must never replace. Released builds resolve to `true` and follow the normal update path.
    private static var isUpdaterEnabledForThisBuild: Bool {
        #if COTABBY_DEV
        false
        #else
        true
        #endif
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
