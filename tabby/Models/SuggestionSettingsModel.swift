import Combine
import Foundation

/// File overview:
/// Owns the user-editable autocomplete preferences that are shared across the app:
/// engine selection, completion length, and the local-model prompt mode preference.
///
/// This type is the right owner for those values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var selectedLocalPromptMode: SuggestionPromptMode

    private let userDefaults: UserDefaults

    private static let selectedEngineDefaultsKey = "selectedSuggestionEngine"
    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let selectedLocalPromptModeDefaultsKey = "selectedLocalSuggestionPromptMode"

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        let resolvedEngine =
            userDefaults
            .string(forKey: Self.selectedEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:))
            ?? .llamaOpenSource
        let resolvedWordCountPreset =
            userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
            ?? configuration.defaultWordCountPreset
        let resolvedLocalPromptMode =
            userDefaults
            .string(forKey: Self.selectedLocalPromptModeDefaultsKey)
            .flatMap(SuggestionPromptMode.init(rawValue:))
            ?? configuration.defaultPromptMode

        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        selectedLocalPromptMode = resolvedLocalPromptMode

        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistSelectedLocalPromptMode(resolvedLocalPromptMode)
    }

    var availablePromptModes: [SuggestionPromptMode] {
        selectedEngine.supportedPromptModes
    }

    var effectivePromptMode: SuggestionPromptMode {
        Self.effectivePromptMode(
            engine: selectedEngine,
            localPromptMode: selectedLocalPromptMode
        )
    }

    var snapshot: SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            effectivePromptMode: effectivePromptMode
        )
    }

    func selectEngine(_ engine: SuggestionEngineKind) {
        guard selectedEngine != engine else {
            return
        }

        selectedEngine = engine
        persistSelectedEngine(engine)
    }

    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        persistSelectedWordCountPreset(preset)
    }

    func selectLocalPromptMode(_ mode: SuggestionPromptMode) {
        guard selectedLocalPromptMode != mode else {
            return
        }

        selectedLocalPromptMode = mode
        persistSelectedLocalPromptMode(mode)
    }

    private static func effectivePromptMode(
        engine: SuggestionEngineKind,
        localPromptMode: SuggestionPromptMode
    ) -> SuggestionPromptMode {
        if engine.supportedPromptModes.contains(localPromptMode) {
            return localPromptMode
        }

        return engine.defaultPromptMode
    }

    private func persistSelectedEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.selectedEngineDefaultsKey)
    }

    private func persistSelectedWordCountPreset(_ preset: SuggestionWordCountPreset) {
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
    }

    private func persistSelectedLocalPromptMode(_ mode: SuggestionPromptMode) {
        userDefaults.set(mode.rawValue, forKey: Self.selectedLocalPromptModeDefaultsKey)
    }
}

extension SuggestionSettingsModel: SuggestionSettingsProviding {
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        Publishers.CombineLatest3(
            $selectedEngine,
            $selectedWordCountPreset,
            $selectedLocalPromptMode
        )
        .map { engine, wordCountPreset, localPromptMode in
            SuggestionSettingsSnapshot(
                selectedEngine: engine,
                selectedWordCountPreset: wordCountPreset,
                effectivePromptMode: Self.effectivePromptMode(
                    engine: engine,
                    localPromptMode: localPromptMode
                )
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
