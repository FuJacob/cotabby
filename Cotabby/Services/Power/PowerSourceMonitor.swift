import AppKit
import Combine
import Foundation
import IOKit.ps

/// Tracks whether the Mac is currently drawing AC power and publishes changes for power-aware
/// features (such as switching the engine/model on battery vs. plugged in).
///
/// Lives on the main actor because `@Published` feeds SwiftUI and both the IOKit run-loop callback
/// and the wake observer are delivered on the main run loop / queue. Live charger plug/unplug is
/// detected via an `IOPSNotificationCreateRunLoopSource`; the wake observer is a safety net for
/// power changes that happen while the machine is asleep.
@MainActor
final class PowerSourceMonitor: ObservableObject {
    @Published private(set) var isPluggedIn = true

    private var wakeObserver: NSObjectProtocol?
    private var runLoopSource: CFRunLoopSource?

    init() {
        refreshPowerState()
        startObservingPowerSourceChanges()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPowerState()
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    /// Registers an IOKit run-loop source that fires whenever the providing power source changes, so
    /// charger plug/unplug is picked up live during an active session rather than only at launch and
    /// on wake. The C callback cannot capture context, so `self` is threaded through the opaque
    /// pointer; the source is added to the main run loop, so the callback runs on the main actor.
    private func startObservingPowerSourceChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let source = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else {
                return
            }

            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(rawContext).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refreshPowerState()
            }
        }, context)?.takeRetainedValue() else {
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
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
