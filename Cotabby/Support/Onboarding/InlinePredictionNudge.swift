import Combine
import Foundation

/// File overview:
/// A one-time reminder, a week into using Cotabby, to turn off macOS inline predictive text.
///
/// Onboarding already points it out on the keys step (`InlinePredictionCallout`), but at that moment
/// the user has not yet seen the two kinds of gray text compete for Tab. After a week they have, so
/// the menu bar popover offers the same link once more. The card shows only while the system switch
/// is still on, disappears for good when dismissed, and disappears by itself once the switch is off.
///
/// "A week" counts from the first launch of a build that knows about this nudge, stamped by
/// `recordStartIfNeeded` at launch: for a new user that is install day, for an existing user the
/// day they updated. Either way they get a week of real use before being asked.
@MainActor
final class InlinePredictionNudge: ObservableObject {
    static let startDateKey = "cotabbyInlinePredictionNudgeStartDate"
    static let dismissedKey = "cotabbyInlinePredictionNudgeDismissed"
    static let delay: TimeInterval = 7 * 24 * 60 * 60

    /// Pure decision, kept separate so the timing rules are testable without defaults or AppKit.
    nonisolated static func shouldShow(
        startDate: Date?,
        now: Date,
        isDismissed: Bool,
        isPredictionEnabled: Bool
    ) -> Bool {
        guard isPredictionEnabled, !isDismissed, let startDate else {
            return false
        }
        return now.timeIntervalSince(startDate) >= delay
    }

    /// Stamps the start of the week on first launch; later launches leave the stamp alone.
    static func recordStartIfNeeded(userDefaults: UserDefaults = .standard, now: Date = Date()) {
        guard userDefaults.object(forKey: startDateKey) == nil else {
            return
        }
        userDefaults.set(now, forKey: startDateKey)
    }

    @Published private(set) var isVisible = false

    private let monitor: SystemInlinePredictionMonitor
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private var monitorObserver: AnyCancellable?

    /// `@MainActor` with stored properties, so without this Swift routes the deinit through the
    /// back-deployed `swift_task_deinitOnExecutorMainActorBackDeploy` shim, whose
    /// `TaskLocal::StopLookupScope` frees a pointer it never allocated on macOS 15 and aborts the
    /// process (CI's test host crashed on every release of one). Releasing the monitor,
    /// defaults, clock closure and Combine subscription needs no main-actor hop.
    nonisolated deinit {}

    init(
        monitor: SystemInlinePredictionMonitor? = nil,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        // Built here rather than as a default argument: default arguments are evaluated outside the
        // main actor, where the monitor's isolated initializer cannot be called.
        let monitor = monitor ?? SystemInlinePredictionMonitor()
        self.monitor = monitor
        self.userDefaults = userDefaults
        self.now = now
        monitorObserver = monitor.$isEnabled
            .sink { [weak self] isEnabled in
                self?.recompute(isPredictionEnabled: isEnabled)
            }
    }

    /// Re-reads the system switch and the clock; called whenever the menu bar popover opens.
    func refresh() {
        monitor.refresh()
        recompute(isPredictionEnabled: monitor.isEnabled)
    }

    func dismiss() {
        userDefaults.set(true, forKey: Self.dismissedKey)
        isVisible = false
    }

    func openKeyboardSettings() {
        monitor.openKeyboardSettings()
    }

    private func recompute(isPredictionEnabled: Bool) {
        let visible = Self.shouldShow(
            startDate: userDefaults.object(forKey: Self.startDateKey) as? Date,
            now: now(),
            isDismissed: userDefaults.bool(forKey: Self.dismissedKey),
            isPredictionEnabled: isPredictionEnabled
        )
        if visible != isVisible {
            isVisible = visible
        }
    }
}
