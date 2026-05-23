import ApplicationServices
import SwiftUI

/// A small inline view that captures the next keypress and reports its key code and label.
/// Installs an `NSEvent` local monitor on appear and removes it on disappear or capture,
/// so no leaked monitors accumulate.
struct KeyRecorderView: View {
    let onKeyRecorded: (CGKeyCode, String) -> Void

    @State private var monitor: Any?

    /// Keys that conflict with the suggestion pipeline's built-in classification.
    private static let reservedKeyCodes: Set<UInt16> = [
        53,                     // Escape
        36, 76,                 // Return, Enter
        123, 124, 125, 126      // Arrow keys
    ]

    var body: some View {
        Text("Press a key…")
            .foregroundStyle(.secondary)
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let keyCode = event.keyCode
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
