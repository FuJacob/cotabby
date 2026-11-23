import Foundation
import Logging
import Sparkle

/// File overview:
/// Owns Cotabby's Sparkle integration and keeps updater lifecycle out of SwiftUI views.
/// This is a classic service-layer boundary in the app's architecture: Sparkle is a side-effectful
/// framework that talks to the network, persists updater preferences, and may present system UI.
///
/// We keep it in `Services/` so the rest of the app only depends on a tiny, explicit surface:
/// `start()` for lifecycle wiring and `checkForUpdates()` for the menu and About pane's manual check.
@MainActor
final class AppUpdateManager {
    /// The updater is created once and retained for the lifetime of the process, just like the
    /// runtime manager and the focus tracker. Sparkle expects its controller to stay alive.
    private let updaterController: SPUStandardUpdaterController

    private var isStarted = false

    private static let debugCheckForUpdatesOnLaunchArgument = "-Cotabby-check-for-updates-on-launch"

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

        if let problem = AppUpdateStartPolicy.configurationProblem(
            feedURL: configuredString(forInfoDictionaryKey: "SUFeedURL"),
            publicKey: configuredString(forInfoDictionaryKey: "SUPublicEDKey")
        ) {
            log(problem)
            log("Sparkle not started because updater configuration is incomplete.")
            return
        }

        // Configure the interval before starting so Sparkle's first scheduling decision uses the
        // daily cadence together with its persisted last-check date. Sparkle persists this setting
        // in user defaults, which take precedence over `CotabbyInfo.plist`, so reapplying it repairs
        // older installs that saved a shorter development interval.
        let updater = updaterController.updater
        updater.updateCheckInterval = AppUpdateStartPolicy.automaticCheckInterval
        updaterController.startUpdater()
        isStarted = true
        log("Sparkle updater started.")

        if AppUpdateStartPolicy.needsCatchUpCheck(lastCheck: updater.lastUpdateCheckDate, now: Date()) {
            updater.checkForUpdatesInBackground()
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.debugCheckForUpdatesOnLaunchArgument) {
            log("Debug launch argument requested an immediate update check.")
            checkForUpdates()
        }
        #endif
    }

    /// UI surfaces (the menu bar item, the About pane) call this instead of touching Sparkle
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
