import Foundation

/// File overview:
/// Centralizes Cotabby's permission metadata in one place.
///
/// Before this file, permission titles, subtitles, required/optional rules, and Settings URLs were
/// spread across multiple views and services. Pulling that information into a model gives the app
/// a single source of truth for permission semantics, while leaving the actual permission checks in
/// `PermissionManager`.
nonisolated enum PermissionGuidanceStyle: Equatable, Sendable {
    /// Launch System Settings and show Cotabby's drag-and-drop helper overlay.
    case guidedOverlay

    /// Launch System Settings without the overlay. This is useful for lower-priority or legacy
    /// permissions where investing in a richer walkthrough does not meaningfully improve the core
    /// product experience.
    case settingsOnly
}

/// Describes one macOS privacy permission Cotabby can request.
///
/// This type deliberately owns metadata only. It does not know whether a permission is granted;
/// that runtime state belongs to `PermissionManager`.
enum CotabbyPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"
    case screenRecording = "Privacy_ScreenCapture"

    var id: Self { self }

    var title: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .inputMonitoring:
            "Input Monitoring"
        case .screenRecording:
            "Screen Recording"
        }
    }

    var systemImageName: String {
        switch self {
        case .accessibility:
            "accessibility"
        case .inputMonitoring:
            "keyboard.fill"
        case .screenRecording:
            "rectangle.dashed.badge.record"
        }
    }

    var onboardingSubtitle: String {
        switch self {
        case .accessibility:
            "Read text fields and caret position."
        case .inputMonitoring:
            "Detect typing and accept with Tab."
        case .screenRecording:
            "Capture screen context for visual reasoning."
        }
    }

    var guidanceHint: String {
        switch guidanceStyle {
        case .guidedOverlay:
            "Cotabby will open System Settings and show a drag helper anchored to the correct list."
        case .settingsOnly:
            "Opens the matching System Settings pane so you can grant it manually."
        }
    }

    var guidanceStyle: PermissionGuidanceStyle {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording:
            .guidedOverlay
        }
    }

    var isRequiredForAutocomplete: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording:
            true
        }
    }

    /// Uses the same deep-link family Cotabby already shipped with.
    ///
    /// Keeping the existing URL shape is a pragmatic compatibility choice: these links are already
    /// known to work in this app, so the refactor can focus on the new guided experience rather
    /// than changing URL behavior at the same time.
    var settingsURL: URL {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") else {
            preconditionFailure("Invalid System Settings URL for permission \(rawValue)")
        }
        return url
    }
}
