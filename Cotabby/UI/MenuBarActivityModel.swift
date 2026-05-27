import Combine
import Foundation

/// File overview:
/// View model behind the menu-bar busy indicator. It watches the three pipeline states, collapses
/// them with `MenuBarActivity.isBusy`, and applies hysteresis so the indicator never flickers.
///
/// Why the hysteresis:
/// Completions cycle through `.generating` on nearly every typing burst and a local generation can
/// finish in tens of milliseconds. Binding the spinner straight to the raw busy flag would strobe
/// the menu bar. Two guards fix that:
///   - a leading delay (`showDelay`): work must stay busy this long before the spinner appears, so
///     sub-threshold completions never show anything;
///   - a minimum on-time (`minimumVisibleDuration`): once shown, the spinner stays up at least this
///     long so a quick busy → idle → busy bounce doesn't blink it off and back on.
@MainActor
final class MenuBarActivityModel: ObservableObject {
    @Published private(set) var isBusy = false

    private let showDelay: Duration
    private let minimumVisibleDuration: Duration
    private var cancellable: AnyCancellable?
    private var pendingShow: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?
    private var shownAt: ContinuousClock.Instant?

    init(
        runtimeModel: RuntimeBootstrapModel,
        suggestionCoordinator: SuggestionCoordinator,
        showDelay: Duration = .milliseconds(250),
        minimumVisibleDuration: Duration = .milliseconds(500)
    ) {
        self.showDelay = showDelay
        self.minimumVisibleDuration = minimumVisibleDuration

        // All three sources are @MainActor @Published, so CombineLatest delivers on the main actor
        // and the derived flag is safe to drive UI directly. `removeDuplicates` avoids re-running the
        // debounce logic for state churn that doesn't change the collapsed busy verdict.
        cancellable = runtimeModel.$state
            .combineLatest(
                suggestionCoordinator.$state,
                suggestionCoordinator.$visualContextStatus
            )
            .map { MenuBarActivity.isBusy(runtime: $0, completion: $1, visual: $2) }
            .removeDuplicates()
            .sink { [weak self] rawBusy in
                self?.updateRawBusy(rawBusy)
            }
    }

    /// Drives the debounced `isBusy` from the collapsed raw signal. `internal` (not `private`) so
    /// unit tests can exercise the hysteresis directly with short thresholds.
    func updateRawBusy(_ rawBusy: Bool) {
        if rawBusy {
            // A fresh burst of work cancels any pending hide so the spinner stays up continuously.
            pendingHide?.cancel()
            pendingHide = nil
            guard !isBusy, pendingShow == nil else {
                return
            }
            pendingShow = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: showDelay)
                guard !Task.isCancelled else { return }
                pendingShow = nil
                isBusy = true
                shownAt = .now
            }
        } else {
            // Work stopped before the spinner ever appeared: drop the pending show silently.
            pendingShow?.cancel()
            pendingShow = nil
            guard isBusy, pendingHide == nil else {
                return
            }
            let elapsed = shownAt.map { ContinuousClock.now - $0 } ?? minimumVisibleDuration
            let remaining = minimumVisibleDuration - elapsed
            guard remaining > .zero else {
                isBusy = false
                shownAt = nil
                return
            }
            pendingHide = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled else { return }
                pendingHide = nil
                isBusy = false
                shownAt = nil
            }
        }
    }
}
