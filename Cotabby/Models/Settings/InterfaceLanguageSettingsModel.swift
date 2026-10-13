import Combine
import Foundation

/// UI-facing owner of Cotabby's interface-language preference. It snapshots the launch selection
/// once, publishes menu state, and writes through a narrow store; it deliberately stays outside
/// `SuggestionSettingsSnapshot` because changing display copy must not restart or reshape generation.
@MainActor
final class InterfaceLanguageSettingsModel: ObservableObject {
    @Published private(set) var selection: InterfaceLanguageSelection
    @Published private(set) var restartRequired = false

    private let store: InterfaceLanguageSettingsStore
    private let launchSelection: InterfaceLanguageSelection

    init(store: InterfaceLanguageSettingsStore = InterfaceLanguageSettingsStore()) {
        self.store = store

        if let firstIdentifier = store.appLanguageIdentifiers()?.first {
            let initialSelection = InterfaceLanguageNormalizer.selection(
                forStoredIdentifier: firstIdentifier
            )
            selection = initialSelection
            launchSelection = initialSelection
        } else {
            selection = .followSystem
            launchSelection = .followSystem
        }
    }

    /// Persists an explicit supported choice. The running process keeps its cached localization
    /// tables, so the view asks the user to restart instead of pretending its copy changed live.
    func select(_ selection: InterfaceLanguageSelection) {
        guard selection != self.selection else { return }

        switch selection {
        case .followSystem:
            store.setAppLanguage(nil)
        case let .language(language):
            store.setAppLanguage(language)
        case .preservedUnsupported:
            // The sentinel is a read-only representation of a preexisting preference. Selecting
            // it again must never invent a new persisted value from an unsupported identifier.
            return
        }

        self.selection = selection
        restartRequired = selection != launchSelection
    }

    /// The General pane's full reset is an explicit request to remove even an unsupported old
    /// override. This can require a restart when the old value was not represented by the menu.
    func resetToFollowSystem() {
        store.setAppLanguage(nil)
        selection = .followSystem
        restartRequired = selection != launchSelection
    }
}
