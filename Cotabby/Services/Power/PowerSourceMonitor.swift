import AppKit
import Combine
import Foundation
import IOKit.ps

/// Tracks whether the Mac is currently drawing AC power and publishes changes for power-aware
/// features (such as switching the local model on battery vs. plugged in).
///
/// Lives on the main actor because `@Published` feeds SwiftUI and the wake observer is delivered on
/// the main queue. State is refreshed at launch and on wake from sleep; live charger plug/unplug
/// during an active session is not yet observed.
@MainActor
final class PowerSourceMonitor: ObservableObject {
    @Published private(set) var isPluggedIn = true

    private var observer: NSObjectProtocol?

    init() {
        refreshPowerState()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPowerState()
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refreshPowerState() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()

        guard let powerSource = IOPSGetProvidingPowerSourceType(snapshot) else {
            return
        }

        let source = powerSource.takeUnretainedValue() as String
        isPluggedIn = source == kIOPSACPowerValue
    }
}
