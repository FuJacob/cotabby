import AppKit
import Foundation
import Logging

/// Owns the release-check action for Cotabby. The app environment retains this service and
/// AppDelegate starts it alongside the other services; views only request a manual update check.
/// Releases currently use GitHub downloads, so startup has no network work and no upstream
/// automatic updater is installed. The fork release URL stays in place until a tested upstream migration exists.
@MainActor
final class AppUpdateManager {
    func start() {
        CotabbyLogger.updates.info("Cotabby updates are checked manually on GitHub.")
    }

    func checkForUpdates() {
        guard let url = URL(string: "https://github.com/mc-hamster/CoHamster/releases") else { return }
        NSWorkspace.shared.open(url)
    }
}
