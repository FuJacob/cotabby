import AppKit
import Foundation
import Logging

/// File overview:
/// Polls the general pasteboard for new text and records it into an in-memory `ClipboardHistoryStore`
/// for the `;;` picker. NSPasteboard has no change notification, so this polls `changeCount` on a
/// light timer. Capturing only happens while the feature is enabled, and respects the standard
/// `org.nspasteboard.*` privacy markers plus Cotabby's own synthetic-write marker (see
/// `ClipboardCaptureFilter`). History lives only in memory and is cleared on quit.
@MainActor
final class ClipboardHistoryService {
    private let pasteboard: NSPasteboard
    private let isEnabled: () -> Bool
    private var store: ClipboardHistoryStore
    private var lastChangeCount: Int
    private var timer: Timer?

    /// Light cadence: a pasteboard `changeCount` read is cheap, and clipboard history does not need
    /// sub-second freshness. Two copies inside one window collapse to the most recent, which is an
    /// accepted limitation of polling.
    private static let pollInterval: TimeInterval = 0.7

    init(
        pasteboard: NSPasteboard = .general,
        capacity: Int = 15,
        isEnabled: @escaping () -> Bool
    ) {
        self.pasteboard = pasteboard
        self.isEnabled = isEnabled
        self.store = ClipboardHistoryStore(capacity: capacity)
        self.lastChangeCount = pasteboard.changeCount
    }

    var items: [ClipboardItem] { store.items }

    func filtered(by query: String) -> [ClipboardItem] {
        store.filtered(by: query)
    }

    func clear() {
        store.clear()
    }

    func start() {
        guard timer == nil else { return }
        // Seed with whatever is already on the clipboard so the picker is useful immediately, not only
        // after the next copy. The capture filter still skips concealed and transient content.
        lastChangeCount = -1
        poll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        CotabbyLogger.app.info("Clipboard history service started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        // Always track the latest change count, even while disabled, so enabling mid-session does not
        // backfill the item that was on the clipboard before the user opted in.
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isEnabled() else { return }
        guard ClipboardCaptureFilter.shouldCapture(types: pasteboard.types ?? []) else { return }
        guard let raw = pasteboard.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let item = ClipboardItem(
            id: UUID(),
            text: raw,
            sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            capturedAt: Date()
        )
        store.record(item)
    }
}
