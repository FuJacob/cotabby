import Combine
import Foundation

/// File overview:
/// Owns the durable autocomplete preferences that are shared across the app:
/// engine selection, completion length, indicator appearance, prompt strategy, and custom
/// writing guidance.
///
/// This type is the right owner for these values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var isGloballyEnabled: Bool
    @Published private(set) var selectedIndicatorMode: ActivationIndicatorMode
    @Published private(set) var customSuggestionTextColorHex: String?
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var streamingAutocompleteEnabled: Bool
    @Published private(set) var selectedLocalPromptMode: SuggestionPromptMode
    @Published private(set) var customAIInstructions: String

    private let userDefaults: UserDefaults

    private static let isGloballyEnabledDefaultsKey = "tabbyGloballyEnabled"
    // Legacy key. Keep reading and writing through it so old builds degrade to a visible indicator.
    private static let showCaretIndicatorDefaultsKey = "tabbyShowCaretIndicator"
    private static let selectedIndicatorModeDefaultsKey = "tabbySelectedIndicatorMode"
    private static let customSuggestionTextColorHexDefaultsKey = "tabbyCustomSuggestionTextColorHex"
    private static let selectedEngineDefaultsKey = "selectedSuggestionEngine"
    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let streamingAutocompleteEnabledDefaultsKey = "tabbyStreamingAutocompleteEnabled"
    private static let selectedLocalPromptModeDefaultsKey = "selectedLocalSuggestionPromptMode"
    private static let customAIInstructionsDefaultsKey = "tabbyCustomAIInstructions"

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let legacyShowCaretIndicator = userDefaults.object(forKey: Self.showCaretIndicatorDefaultsKey) as? Bool ?? true
        let resolvedIndicatorMode = userDefaults
            .string(forKey: Self.selectedIndicatorModeDefaultsKey)
            .flatMap(ActivationIndicatorMode.init(rawValue:))
            ?? Self.migrateIndicatorMode(fromLegacyShowCaretIndicator: legacyShowCaretIndicator)
        let resolvedCustomSuggestionTextColorHex = Self.normalizedHexString(
            userDefaults.string(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        )
        let resolvedEngine = userDefaults
            .string(forKey: Self.selectedEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:))
            ?? .llamaOpenSource
        let resolvedWordCountPreset = userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
            ?? configuration.defaultWordCountPreset
        let resolvedStreamingAutocompleteEnabled = userDefaults
            .object(forKey: Self.streamingAutocompleteEnabledDefaultsKey) as? Bool ?? false
        let resolvedLocalPromptMode = userDefaults
            .string(forKey: Self.selectedLocalPromptModeDefaultsKey)
            .flatMap(SuggestionPromptMode.init(rawValue:))
            ?? configuration.defaultPromptMode
        let resolvedCustomAIInstructions: String = if userDefaults.object(forKey: Self.customAIInstructionsDefaultsKey) == nil {
            configuration.defaultCustomAIInstructions ?? ""
        } else {
            userDefaults.string(forKey: Self.customAIInstructionsDefaultsKey) ?? ""
        }

        isGloballyEnabled = resolvedGloballyEnabled
        selectedIndicatorMode = resolvedIndicatorMode
        customSuggestionTextColorHex = resolvedCustomSuggestionTextColorHex
        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        streamingAutocompleteEnabled = resolvedStreamingAutocompleteEnabled
        selectedLocalPromptMode = resolvedLocalPromptMode
        customAIInstructions = resolvedCustomAIInstructions

        userDefaults.set(resolvedGloballyEnabled, forKey: Self.isGloballyEnabledDefaultsKey)
        persistSelectedIndicatorMode(resolvedIndicatorMode)
        persistCustomSuggestionTextColorHex(resolvedCustomSuggestionTextColorHex)
        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistStreamingAutocompleteEnabled(resolvedStreamingAutocompleteEnabled)
        persistSelectedLocalPromptMode(resolvedLocalPromptMode)
        persistCustomAIInstructions(resolvedCustomAIInstructions)
    }

    /// Compatibility shim for legacy call sites while the UI migrates from the old toggle to the
    /// richer indicator-mode picker.
    var showCaretIndicator: Bool {
        selectedIndicatorMode != .hidden
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
            isGloballyEnabled: isGloballyEnabled,
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            streamingAutocompleteEnabled: streamingAutocompleteEnabled,
            effectivePromptMode: effectivePromptMode,
            customAIInstructions: CustomAIInstructionFormatter.normalized(customAIInstructions)
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

    func setStreamingAutocompleteEnabled(_ enabled: Bool) {
        guard streamingAutocompleteEnabled != enabled else {
            return
        }

        streamingAutocompleteEnabled = enabled
        persistStreamingAutocompleteEnabled(enabled)
    }

    func selectLocalPromptMode(_ mode: SuggestionPromptMode) {
        guard selectedLocalPromptMode != mode else {
            return
        }

        selectedLocalPromptMode = mode
        persistSelectedLocalPromptMode(mode)
    }

    func setGloballyEnabled(_ enabled: Bool) {
        guard isGloballyEnabled != enabled else {
            return
        }

        isGloballyEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isGloballyEnabledDefaultsKey)
    }

    func selectIndicatorMode(_ mode: ActivationIndicatorMode) {
        guard selectedIndicatorMode != mode else {
            return
        }

        selectedIndicatorMode = mode
        persistSelectedIndicatorMode(mode)
    }

    /// Compatibility shim for old toggle-driven call sites. Turning the toggle back on restores the
    /// caret-anchor indicator because that was the historic behavior users opted into.
    func setShowCaretIndicator(_ show: Bool) {
        selectIndicatorMode(show ? .caretAnchor : .hidden)
    }

    func setCustomSuggestionTextColorHex(_ hex: String?) {
        let normalizedHex = Self.normalizedHexString(hex)
        guard customSuggestionTextColorHex != normalizedHex else {
            return
        }

        customSuggestionTextColorHex = normalizedHex
        persistCustomSuggestionTextColorHex(normalizedHex)
    }

    func setCustomAIInstructions(_ instructions: String) {
        guard customAIInstructions != instructions else {
            return
        }

        customAIInstructions = instructions
        persistCustomAIInstructions(instructions)
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

    private func persistStreamingAutocompleteEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.streamingAutocompleteEnabledDefaultsKey)
    }

    private func persistSelectedLocalPromptMode(_ mode: SuggestionPromptMode) {
        userDefaults.set(mode.rawValue, forKey: Self.selectedLocalPromptModeDefaultsKey)
    }

    private func persistSelectedIndicatorMode(_ mode: ActivationIndicatorMode) {
        userDefaults.set(mode.rawValue, forKey: Self.selectedIndicatorModeDefaultsKey)
        userDefaults.set(mode != .hidden, forKey: Self.showCaretIndicatorDefaultsKey)
    }

    private func persistCustomSuggestionTextColorHex(_ hex: String?) {
        if let hex {
            userDefaults.set(hex, forKey: Self.customSuggestionTextColorHexDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        }
    }

    private static func migrateIndicatorMode(
        fromLegacyShowCaretIndicator showCaretIndicator: Bool
    ) -> ActivationIndicatorMode {
        showCaretIndicator ? .caretAnchor : .hidden
    }

    private static func normalizedHexString(_ hex: String?) -> String? {
        guard let hex else {
            return nil
        }

        let trimmed = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        let validCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard trimmed.count == 6,
              trimmed.unicodeScalars.allSatisfy(validCharacters.contains(_:))
        else {
            return nil
        }

        return trimmed
    }

    private func persistCustomAIInstructions(_ instructions: String) {
        userDefaults.set(instructions, forKey: Self.customAIInstructionsDefaultsKey)
    }
}

extension SuggestionSettingsModel: SuggestionSettingsProviding {
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                $isGloballyEnabled,
                $selectedEngine,
                $selectedWordCountPreset,
                $streamingAutocompleteEnabled
            ),
            Publishers.CombineLatest(
                $selectedLocalPromptMode,
                $customAIInstructions
            )
        )
        .map { combinedSettings, promptSettings in
            let (globallyEnabled, engine, wordCountPreset, streamingAutocompleteEnabled) = combinedSettings
            let (localPromptMode, customAIInstructions) = promptSettings
            return SuggestionSettingsSnapshot(
                isGloballyEnabled: globallyEnabled,
                selectedEngine: engine,
                selectedWordCountPreset: wordCountPreset,
                streamingAutocompleteEnabled: streamingAutocompleteEnabled,
                effectivePromptMode: Self.effectivePromptMode(
                    engine: engine,
                    localPromptMode: localPromptMode
                ),
                customAIInstructions: CustomAIInstructionFormatter.normalized(customAIInstructions)
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
