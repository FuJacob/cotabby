import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Logging

/// File overview:
/// Polls and exposes the three system permissions Cotabby depends on: Accessibility for reading
/// focus state, Input Monitoring for global key capture, and Screen Recording for screenshot
/// context that improves autocomplete relevance.
///
/// `@MainActor` guarantees permission state is mutated on the UI thread.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var screenRecordingGranted = false

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Keeps UI state aligned with permission changes the user makes in System Settings.
    ///
    /// A permission can only change while the user is in System Settings, i.e. while Cotabby is
    /// backgrounded; returning to the app fires `didBecomeActive`, and the menu/settings surfaces
    /// already call `refresh()` when they appear. So instead of a forever-running 2s poll (a 0.5 Hz
    /// main-thread wake for the whole session, long after every grant is already in place), we
    /// refresh on activation and keep the short catch-up poll alive ONLY while a required permission
    /// is still missing — the onboarding window where snappy feedback matters. Once the required set
    /// is granted the timer is torn down, so an established user pays zero idle wakeups here.
    init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer closure is not formally actor-isolated even though `queue: .main`
            // guarantees main-thread delivery. `assumeIsolated` makes the hop explicit for strict
            // concurrency checking (and keeps the refresh synchronous with activation, so surfaces
            // reading permission state on this same turn see fresh values). Same pattern as
            // `SystemMetricsStore`'s main-queue timer.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // `refresh()` also (re)configures polling for the current grant state, so a process that
        // launches with every permission already granted never arms the timer at all.
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Re-reads the current system permission state and republishes any changes to observers.
    func refresh() {
        let latestAccessibilityGranted = AXIsProcessTrusted()
        let latestInputMonitoringGranted = CGPreflightListenEventAccess()
        let latestScreenRecordingGranted = CGPreflightScreenCaptureAccess()

        // `@Published` notifies on assignment, even when the value is unchanged. Compare first so
        // the 2-second poll does not redraw SwiftUI surfaces that already have the right state.
        if accessibilityGranted != latestAccessibilityGranted {
            CotabbyLogger.app.info("Accessibility permission changed: \(latestAccessibilityGranted)")
            accessibilityGranted = latestAccessibilityGranted
        }

        if inputMonitoringGranted != latestInputMonitoringGranted {
            CotabbyLogger.app.info("Input Monitoring permission changed: \(latestInputMonitoringGranted)")
            inputMonitoringGranted = latestInputMonitoringGranted
        }

        if screenRecordingGranted != latestScreenRecordingGranted {
            CotabbyLogger.app.info("Screen Recording permission changed: \(latestScreenRecordingGranted)")
            screenRecordingGranted = latestScreenRecordingGranted
        }

        updatePollingForCurrentState()
    }

    /// Arms the 2-second catch-up poll only while a required permission is still missing, and stops
    /// it once the required set is granted. Permission changes after that are rare and deliberate,
    /// and every one is followed by the user returning to the app (`didBecomeActive`) or opening a
    /// Cotabby surface that already calls `refresh()`, so the standing timer buys nothing but idle
    /// main-thread wakeups.
    private func updatePollingForCurrentState() {
        if requiredPermissionsGranted {
            stopPolling()
        } else {
            startPollingIfNeeded()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }
        let pollTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        // Menu panels and drag sessions can move the main run loop out of its default mode. Common
        // modes keep the permission cache from freezing during exactly the flows that change
        // permissions.
        RunLoop.main.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Asks macOS to register or prompt for the current process before showing manual guidance.
    ///
    /// The drag helper is useful once the user is in System Settings, but TCC permissions are
    /// ultimately granted to the current app's code identity. Calling the native request API first
    /// makes macOS resolve that identity itself instead of relying only on a file dragged into the
    /// Settings table.
    @discardableResult
    func requestSystemAccess(for permission: CotabbyPermissionKind) -> Bool {
        let granted: Bool

        switch permission {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            granted = AXIsProcessTrustedWithOptions(options)

        case .inputMonitoring:
            granted = CGRequestListenEventAccess()

        case .screenRecording:
            granted = CGRequestScreenCaptureAccess()
        }

        refresh()
        return granted
    }

    /// Returns the latest cached grant state for a specific permission kind.
    ///
    /// Keeping this switch here means higher-level UI can reason in terms of `CotabbyPermissionKind`
    /// instead of hard-coding three separate boolean properties everywhere.
    func isGranted(_ permission: CotabbyPermissionKind) -> Bool {
        switch permission {
        case .accessibility:
            accessibilityGranted
        case .inputMonitoring:
            inputMonitoringGranted
        case .screenRecording:
            screenRecordingGranted
        }
    }

    /// Core autocomplete depends on Accessibility and Input Monitoring. Screen Recording is
    /// optional (without it the app runs the text-only Fast Mode path), so it is intentionally
    /// excluded here via `CotabbyPermissionKind.isRequiredForAutocomplete`.
    var requiredPermissionsGranted: Bool {
        CotabbyPermissionKind.allCases
            .filter(\.isRequiredForAutocomplete)
            .allSatisfy(isGranted(_:))
    }

    /// Shared opener used by onboarding and the menu-bar shortcuts.
    func openSettings(for permission: CotabbyPermissionKind) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// Opens System Settings directly to the Accessibility pane so the user can grant access.
    func openAccessibilitySettings() {
        openSettings(for: .accessibility)
    }

    /// Opens System Settings directly to the Input Monitoring pane so the user can grant access.
    func openInputMonitoringSettings() {
        openSettings(for: .inputMonitoring)
    }

    /// Opens System Settings directly to the Screen Recording pane for visual context capture.
    func openScreenRecordingSettings() {
        openSettings(for: .screenRecording)
    }
}

extension PermissionManager: SuggestionPermissionProviding {
    /// The coordinator subscribes through erased publishers so it can depend on a protocol instead
    /// of the concrete `@Published` storage details of `PermissionManager`.
    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> {
        $inputMonitoringGranted.eraseToAnyPublisher()
    }

    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> {
        $screenRecordingGranted.eraseToAnyPublisher()
    }
}
