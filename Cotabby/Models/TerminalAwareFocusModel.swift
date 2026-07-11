import Combine
import Foundation

/// Publishes the focus source the suggestion pipeline should trust right now.
///
/// `FocusTrackingModel` remains the owner of raw Accessibility state. Terminal shells and TUIs,
/// however, have an authoritative text source outside AX. This model arbitrates between those
/// sources without teaching the AX tracker about sockets, OCR, or shell sessions. The suggestion
/// coordinator observes this model, while menus, emoji/macros, and diagnostics can keep observing
/// the unmodified AX model.
///
/// A terminal override survives same-app unsupported AX polls (the normal terminal case). It is
/// released immediately when the user changes apps, or when a supported non-terminal field inside
/// an embedded host such as VS Code reclaims focus. This prevents a stale terminal buffer from
/// shadowing the editor that shares its process.
@MainActor
final class TerminalAwareFocusModel: ObservableObject, SuggestionFocusProviding {
    @Published private(set) var snapshot: FocusSnapshot

    /// Lets the terminal coordinators cancel source-specific work when AX reclaims effective focus.
    var onTerminalOverrideCleared: (() -> Void)?

    private struct Override {
        let bundleIdentifier: String
        let elementIdentifier: String
        let role: String
    }

    private let accessibilityModel: FocusTrackingModel
    private var activeOverride: Override?
    private var injectedFocusSequence: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    init(accessibilityModel: FocusTrackingModel) {
        self.accessibilityModel = accessibilityModel
        snapshot = accessibilityModel.snapshot

        accessibilityModel.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.applyAccessibilitySnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    /// Makes a shell- or OCR-sourced input the coordinator's effective focus.
    ///
    /// Terminal focus sequences occupy the upper half of `UInt64`, keeping them disjoint from the
    /// AX tracker's ordinary monotonic counter for any realistic app lifetime. The sequence changes
    /// only when the terminal input identity changes; buffer and geometry updates inside the same
    /// shell/TUI retain one focus session and use content/source revisions for freshness.
    func publishTerminalContext(_ context: FocusedInputSnapshot) {
        let identityChanged = activeOverride?.elementIdentifier != context.elementIdentifier
            || activeOverride?.role != context.role
        if activeOverride == nil || identityChanged {
            injectedFocusSequence &+= 1
        }

        let taggedContext = context.withFocusChangeSequence(
            (UInt64(1) << 63) | injectedFocusSequence
        )
        activeOverride = Override(
            bundleIdentifier: taggedContext.bundleIdentifier,
            elementIdentifier: taggedContext.elementIdentifier,
            role: taggedContext.role
        )

        publishIfChanged(
            FocusSnapshot(
                applicationName: taggedContext.applicationName,
                bundleIdentifier: taggedContext.bundleIdentifier,
                capability: .supported,
                context: taggedContext,
                inspection: nil
            )
        )
    }

    /// Releases any terminal override and immediately restores the latest real AX snapshot.
    /// `role` scopes teardown so a stale TUI callback cannot accidentally clear a newer shell source.
    func clearTerminalContext(ifRole role: String? = nil) {
        guard let activeOverride else { return }
        if let role, activeOverride.role != role {
            return
        }

        self.activeOverride = nil
        publishIfChanged(accessibilityModel.snapshot)
        onTerminalOverrideCleared?()
    }

    var hasTerminalOverride: Bool {
        activeOverride != nil
    }

    var terminalOverrideRole: String? {
        activeOverride?.role
    }

    var millisecondsSinceLastCapture: Int? {
        accessibilityModel.millisecondsSinceLastCapture
    }

    func refreshNow() {
        accessibilityModel.refreshNow()
    }

    func invalidateTransientCaretCaches() {
        accessibilityModel.invalidateTransientCaretCaches()
    }

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }

    private func applyAccessibilitySnapshot(_ accessibilitySnapshot: FocusSnapshot) {
        guard let activeOverride else {
            publishIfChanged(accessibilitySnapshot)
            return
        }

        guard accessibilitySnapshot.bundleIdentifier == activeOverride.bundleIdentifier else {
            self.activeOverride = nil
            publishIfChanged(accessibilitySnapshot)
            onTerminalOverrideCleared?()
            return
        }

        // Editors and command palettes inside embedded-terminal hosts share the terminal's bundle
        // identifier. A supported, non-xterm AX field is positive evidence that the user left the
        // terminal pane, so it must reclaim focus immediately. Dedicated terminal apps never reach
        // this branch because their opaque text surfaces remain unsupported.
        if TerminalAppDetector.hostsEmbeddedTerminal(
            bundleIdentifier: activeOverride.bundleIdentifier
        ), accessibilitySnapshot.capability == .supported,
           accessibilitySnapshot.context?.isIntegratedTerminal != true {
            self.activeOverride = nil
            publishIfChanged(accessibilitySnapshot)
            onTerminalOverrideCleared?()
        }
    }

    private func publishIfChanged(_ next: FocusSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
    }
}
