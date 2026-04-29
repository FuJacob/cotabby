import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// File overview:
/// Polls and exposes the three system permissions Tabby depends on: Accessibility for reading
/// focus state, Input Monitoring for global key capture, and Screen Recording for legacy screenshot
/// experiments that are currently deprecated in the autocomplete request path.
///
/// `@MainActor` guarantees permission state is mutated on the UI thread.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var screenRecordingGranted = false

    private var pollTimer: Timer?

    /// Polling keeps UI state aligned with system settings changes performed outside the app.
    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Re-reads the current system permission state and republishes any changes to observers.
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    /// Returns the latest cached grant state for a specific permission kind.
    ///
    /// Keeping this switch here means higher-level UI can reason in terms of `TabbyPermissionKind`
    /// instead of hard-coding three separate boolean properties everywhere.
    func isGranted(_ permission: TabbyPermissionKind) -> Bool {
        switch permission {
        case .accessibility:
            accessibilityGranted
        case .inputMonitoring:
            inputMonitoringGranted
        case .screenRecording:
            screenRecordingGranted
        }
    }

    /// Core autocomplete depends on Accessibility, Input Monitoring, and Screen Recording.
    ///
    /// Screen Recording was historically optional, but is now a core requirement for providing
    /// visual context to the autocomplete engine.
    var requiredPermissionsGranted: Bool {
        TabbyPermissionKind.allCases
            .filter(\.isRequiredForAutocomplete)
            .allSatisfy(isGranted(_:))
    }

    /// Shared opener used by onboarding and the menu-bar shortcuts.
    func openSettings(for permission: TabbyPermissionKind) {
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

    /// Opens System Settings directly to the Screen Recording pane for legacy screenshot tooling.
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
