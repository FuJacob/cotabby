import Combine
import Foundation

/// File overview:
/// Retains the bounded, observable diagnostics history used by the persistent debug panel.
///
/// This is a store rather than a logger. The distinction matters: loggers decide how to emit
/// events, while this object owns the in-memory state SwiftUI observes. Keeping the store bounded
/// prevents debug mode from becoming an accidental memory leak during long app sessions.
@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var recentEvents: [DiagnosticEvent] = []
    @Published private(set) var recentAXNotifications: [FocusObserverEvent] = []

    private let maxEventCount: Int
    private let maxAXNotificationCount: Int

    init(
        maxEventCount: Int = 80,
        maxAXNotificationCount: Int = 24
    ) {
        self.maxEventCount = max(1, maxEventCount)
        self.maxAXNotificationCount = max(1, maxAXNotificationCount)
    }

    /// Appends a structured event and trims oldest entries once the ring buffer is full.
    func record(_ event: DiagnosticEvent) {
        recentEvents.append(event)
        trimEventsIfNeeded()
    }

    /// Records a raw Accessibility notification for fast triage.
    ///
    /// AX notifications are also mirrored into the structured log stream so the panel has both a
    /// compact "active notifications" list and a chronological mixed event feed.
    func recordAXNotification(_ event: FocusObserverEvent) {
        recentAXNotifications.append(event)
        trimAXNotificationsIfNeeded()

        record(DiagnosticEvent(
            level: .trace,
            category: .accessibility,
            component: "AXObserver",
            message: "Notification received",
            metadata: [
                "sequence": String(event.sequence),
                "notification": event.displayName
            ]
        ))
    }

    /// Clears diagnostic buffers when debug mode is disabled.
    ///
    /// Dropping old data makes the next debug session easier to interpret because every event in
    /// the panel belongs to the currently enabled window.
    func reset() {
        recentEvents = []
        recentAXNotifications = []
    }

    private func trimEventsIfNeeded() {
        guard recentEvents.count > maxEventCount else {
            return
        }

        recentEvents.removeFirst(recentEvents.count - maxEventCount)
    }

    private func trimAXNotificationsIfNeeded() {
        guard recentAXNotifications.count > maxAXNotificationCount else {
            return
        }

        recentAXNotifications.removeFirst(recentAXNotifications.count - maxAXNotificationCount)
    }
}
