import ApplicationServices
import SwiftUI

/// A small inline view that captures the next keypress and reports its key code and label.
/// Installs an `NSEvent` local monitor on appear and removes it on disappear or capture,
/// so no leaked monitors accumulate.
struct KeyRecorderView: View {
    let onKeyRecorded: (CGKeyCode, String) -> Void
    var onCancelled: (() -> Void)?

    @State private var monitor: Any?

    /// Keys that conflict with the suggestion pipeline's built-in classification.
    /// Escape (53) is also handled above as the cancel-recording key, but lives here too
    /// so it stays reserved even if the cancel logic changes.
    private static let reservedKeyCodes: Set<UInt16> = [
        36, 76,                 // Return, Enter
        51, 117,                // Delete, Forward Delete
        53,                     // Escape
        123, 124, 125, 126      // Arrow keys
    ]

    var body: some View {
        Text("Press a key…")
            .foregroundStyle(.secondary)
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let keyCode = event.keyCode

            if keyCode == 53 { // Escape cancels recording
                removeMonitor()
                onCancelled?()
                return nil
            }

            guard !Self.reservedKeyCodes.contains(keyCode) else {
                return event
            }

            let label = KeyCodeLabels.label(
                for: CGKeyCode(keyCode),
                fallback: event.charactersIgnoringModifiers
            )
            removeMonitor()
            onKeyRecorded(CGKeyCode(keyCode), label)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
