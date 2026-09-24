import AppKit
import Foundation
import Logging

/// Owns the release-check action for CoHamster. The app environment retains this service and
/// AppDelegate starts it alongside the other services; views only request a manual update check.
/// Releases currently use GitHub downloads, so startup has no network work and no upstream
/// Sparkle controller is created. This prevents an inherited update feed replacing the fork.
@MainActor
final class AppUpdateManager {
    func start() {
        CotabbyLogger.updates.info("CoHamster updates are checked manually on GitHub.")
    }

    func checkForUpdates() {
        guard let url = URL(string: "https://github.com/mc-hamster/CoHamster/releases") else { return }
        NSWorkspace.shared.open(url)
    }
}
