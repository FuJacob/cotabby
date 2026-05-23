import Combine
import Foundation
import ServiceManagement

/// File overview:
/// Wraps macOS login-item registration behind a small app-owned service.
///
/// Why this type exists:
/// "Open at Login" is not just a stored preference. It is a real OS registration side effect that
/// can fail, require approval, or become unavailable in a misconfigured build. Keeping that logic
/// out of `SuggestionSettingsModel` preserves a clean boundary between plain app preferences and
/// operating-system integration.
enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)

    var isEnabled: Bool {
        if case .enabled = self {
            return true
        }

        return false
    }

    var canToggle: Bool {
        if case .unavailable = self {
            return false
        }

        return true
    }

    var detail: String? {
        switch self {
        case .enabled, .disabled:
            return nil
        case .requiresApproval:
            return "macOS requires approval for this login item in System Settings."
        case let .unavailable(message):
            return message
        }
    }
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState
    @Published private(set) var lastErrorMessage: String?

    private let appService: SMAppService

    init(appService: SMAppService = .mainApp) {
        self.appService = appService
        state = Self.map(appService.status)
    }

    /// Re-reads the current login-item status from macOS.
    /// This lets the Settings UI reflect out-of-band changes made in System Settings.
    func refresh() {
        state = Self.map(appService.status)
    }

    /// Registers or unregisters the main app as a login item.
    /// We immediately refresh after mutation so the UI reflects the actual OS state rather than
    /// assuming the request succeeded.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try appService.register()
            } else {
                try appService.unregister()
            }

            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        refresh()
    }

    private static func map(_ status: SMAppService.Status) -> LaunchAtLoginState {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable("Move tabby to the Applications folder and relaunch to enable this.")
        @unknown default:
            return .unavailable("Open at Login is unavailable for an unknown reason.")
        }
    }
}
