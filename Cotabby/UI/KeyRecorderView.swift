import ApplicationServices
import SwiftUI

/// A small inline view that captures the next keypress and reports its key code and label.
/// Installs an `NSEvent` local monitor on appear and removes it on disappear or capture,
/// so no leaked monitors accumulate.
struct KeyRecorderView: View {
    let onKeyRecorded: (CGKeyCode, String) -> Void
    var onCancelled: (() -> Void)?

    @State private var monitor: Any?

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

            // Escape cancels recording rather than binding, so it stays the universal "get me out"
            // affordance. This is the recorder's only keyboard cancel, not a pipeline restriction.
            if keyCode == 53 {
                removeMonitor()
                onCancelled?()
                return nil
            }

            // Any other key is fair game. The pipeline is key-agnostic: `InputMonitor.classify`
            // matches the bound accept key before its behavioral branches, and acceptance only
            // consumes the key while a suggestion is visible (otherwise it passes through and does
            // its normal job). So even Return/Delete are safe to bind — they only intercept in the
            // moment a suggestion is showing.
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
