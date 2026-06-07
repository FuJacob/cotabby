import Foundation
import AppKit
import IOKit


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

    guard let source = IOPSGetProvidingPowerSourceType(snapshot)?
        .takeUnretainedValue() as String else {
        return
    }

    isPluggedIn = source == kIOPSACPowerValue
}
}