import Combine
import Foundation

/// File overview:
/// Publishes focused-input snapshots to SwiftUI and other main-actor consumers. It keeps
/// Accessibility polling details hidden behind a small observable interface.
///
/// Bridges the polling-based focus tracker into SwiftUI-facing published state.
@MainActor
final class FocusTrackingModel: ObservableObject {
    @Published private(set) var snapshot: FocusSnapshot
    @Published private(set) var latestExternalApplication: FocusedApplicationIdentity?
    /// Debug-only polling diagnostics for the bottom-edge overlay; not used by suggestion generation.
    @Published private(set) var latestPollEvent: FocusPollingEvent?

    private let tracker: FocusTracker
    private let ignoredBundleIdentifier: String?
    private var isStarted = false

    init(
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        publishesPollingEvents: Bool = false
    ) {
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        tracker = FocusTracker(
            permissionProvider: permissionProvider,
            ignoredBundleIdentifier: ignoredBundleIdentifier
        )
        snapshot = tracker.snapshot
        latestExternalApplication = tracker.snapshot.externalApplicationIdentity(
            ignoredBundleIdentifier: ignoredBundleIdentifier
        )

        tracker.onSnapshotChange = { [weak self] snapshot in
            self?.snapshot = snapshot
            self?.updateLatestExternalApplication(from: snapshot)
        }

        if publishesPollingEvents {
            tracker.onPoll = { [weak self] event in
                self?.latestPollEvent = event
            }
        }
    }

    /// Starts focus observation once and treats later calls as a request for an immediate refresh.
    func start() {
        guard !isStarted else {
            tracker.refreshNow()
            return
        }

        isStarted = true
        tracker.start()
    }

    /// Stops observation while leaving the last captured snapshot available for UI consumers.
    func stop() {
        isStarted = false
        tracker.stop()
    }

    /// A manual refresh is useful when another subsystem already knows "input just changed" and
    /// wants the latest AX snapshot immediately instead of waiting for the next timer tick.
    func refreshNow() {
        tracker.refreshNow()
    }

    /// The menu bar needs a compact status string, not the full diagnostic reason.
    var menuBarStatusText: String {
        snapshot.capability.shortLabel
    }

    var menuBarSymbolName: String {
        switch snapshot.capability {
        case .supported:
            return "checkmark.circle"
        case .blocked:
            return "hand.raised.circle"
        case .unsupported:
            return "xmark.circle"
        }
    }

    private func updateLatestExternalApplication(from snapshot: FocusSnapshot) {
        guard let application = snapshot.externalApplicationIdentity(
            ignoredBundleIdentifier: ignoredBundleIdentifier
        ) else {
            return
        }

        latestExternalApplication = application
    }
}

extension FocusTrackingModel: SuggestionFocusProviding {
    /// Exposing an erased publisher keeps `SuggestionCoordinator` coupled to "a stream of focus
    /// snapshots" rather than the implementation detail that this model uses `@Published`.
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }
}
