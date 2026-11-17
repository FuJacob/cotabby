import AppKit
import Combine

/// File overview:
/// Tracks whether macOS inline predictive text is on, so onboarding can suggest turning it off.
///
/// Sonoma and later ship "Show inline predictive text" switched on: the system draws its own gray
/// completion after the caret in every NSTextView and accepts it with Tab. With Cotabby running the
/// user sees two kinds of gray text competing for the same key. Cotabby already steps aside while the
/// host's prediction is on screen (`HostMarkedTextPolicy`), but it cannot and should not flip a
/// system-wide preference on the user's behalf, so the onboarding keys step explains the overlap and
/// links to Keyboard settings.
///
/// The value is re-read whenever Cotabby becomes active again, which is the moment the user returns
/// from System Settings after changing it; the hint then disappears on its own.
@MainActor
final class SystemInlinePredictionMonitor: ObservableObject {
    /// Keyboard settings, where "Text Input › Edit…" holds the inline predictive text switch. The
    /// switch itself sits in a sheet that has no deep link of its own.
    static let keyboardSettingsURL: URL = {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
            preconditionFailure("Invalid Keyboard settings URL")
        }
        return url
    }()

    @Published private(set) var isEnabled: Bool

    private let readIsEnabled: () -> Bool
    private var activationObserver: AnyCancellable?

    init(
        readIsEnabled: @escaping () -> Bool = { NSSpellChecker.isAutomaticInlinePredictionEnabled },
        notificationCenter: NotificationCenter = .default
    ) {
        self.readIsEnabled = readIsEnabled
        isEnabled = readIsEnabled()
        activationObserver = notificationCenter
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
    }

    func refresh() {
        let current = readIsEnabled()
        if current != isEnabled {
            isEnabled = current
        }
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(Self.keyboardSettingsURL)
    }
}
