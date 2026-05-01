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
    @Published private(set) var disabledAppRules: [DisabledApplicationRule]
    @Published private(set) var customSuggestionTextColorHex: String?
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var selectedLocalPromptMode: SuggestionPromptMode
    @Published private(set) var customAIInstructions: String
    /// When enabled, the llama runtime applies a `-inf` logit bias to known chat-residue tokens
    /// (e.g. "Sure,", "Here's", "I ") on the first generated token only.
    /// This prevents instruction-tuned models from starting suggestions with conversational
    /// openers that belong in a chat reply, not in inline autocomplete.
    @Published private(set) var isFirstTokenGatingEnabled: Bool
    /// When enabled, the llama runtime measures the top-1 raw-logit softmax probability of the
    /// first sampled token and silently suppresses the whole suggestion if it falls below
    /// `firstTokenConfidenceThreshold`. This is a *separate* axis from chat-opener gating:
    /// gating masks specific tokens; confidence suppression aborts generation entirely when
    /// the model's own distribution is too flat to produce a trustworthy continuation.
    @Published private(set) var isFirstTokenConfidenceGatingEnabled: Bool
    /// Probability threshold in [0, 1]. Higher values are stricter (more suggestions are
    /// suppressed). 0 effectively disables the gate even when the toggle is on.
    @Published private(set) var firstTokenConfidenceThreshold: Double

    private let userDefaults: UserDefaults

    private static let isGloballyEnabledDefaultsKey = "tabbyGloballyEnabled"
    private static let disabledAppRulesDefaultsKey = "tabbyDisabledAppRules"
    // Legacy key. Keep reading and writing through it so old builds degrade to a visible indicator.
    private static let showCaretIndicatorDefaultsKey = "tabbyShowCaretIndicator"
    private static let selectedIndicatorModeDefaultsKey = "tabbySelectedIndicatorMode"
    private static let customSuggestionTextColorHexDefaultsKey = "tabbyCustomSuggestionTextColorHex"
    private static let selectedEngineDefaultsKey = "selectedSuggestionEngine"
    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let selectedLocalPromptModeDefaultsKey = "selectedLocalSuggestionPromptMode"
    private static let customAIInstructionsDefaultsKey = "tabbyCustomAIInstructions"
    private static let isFirstTokenGatingEnabledDefaultsKey = "tabbyFirstTokenGatingEnabled"
    private static let confidenceGatingEnabledDefaultsKey = "tabbyFirstTokenConfidenceGatingEnabled"
    private static let confidenceThresholdDefaultsKey = "tabbyFirstTokenConfidenceThreshold"

    /// 0.10 is a deliberately gentle starting point: our local models often peak at ~0.30-0.60
    /// for unambiguous continuations, so this threshold catches only the genuinely-confused
    /// cases (e.g. the model sees the prompt as ambiguous and spreads probability widely).
    /// We expect to tune this once telemetry from the `first-token-confidence` log accumulates.
    private static let defaultFirstTokenConfidenceThreshold: Double = 0.10

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let resolvedDisabledAppRules = Self.loadDisabledAppRules(from: userDefaults)
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
        let resolvedLocalPromptMode = userDefaults
            .string(forKey: Self.selectedLocalPromptModeDefaultsKey)
            .flatMap(SuggestionPromptMode.init(rawValue:))
            ?? configuration.defaultPromptMode
        let resolvedCustomAIInstructions: String = if userDefaults.object(forKey: Self.customAIInstructionsDefaultsKey) == nil {
            configuration.defaultCustomAIInstructions ?? ""
        } else {
            userDefaults.string(forKey: Self.customAIInstructionsDefaultsKey) ?? ""
        }
        // Default to enabled — first-token gating is a net positive for all known instruct models.
        let resolvedFirstTokenGatingEnabled = userDefaults.object(forKey: Self.isFirstTokenGatingEnabledDefaultsKey) as? Bool ?? true
        // Default off until we've seen field telemetry. The deny-list gate ships on by default
        // because it's evidence-backed and surgical; confidence suppression is heuristic and can
        // hide useful suggestions when the threshold is mistuned, so users opt in explicitly.
        let resolvedConfidenceGatingEnabled = userDefaults
            .object(forKey: Self.confidenceGatingEnabledDefaultsKey) as? Bool ?? false
        let resolvedConfidenceThreshold: Double = {
            guard userDefaults.object(forKey: Self.confidenceThresholdDefaultsKey) != nil else {
                return Self.defaultFirstTokenConfidenceThreshold
            }
            let raw = userDefaults.double(forKey: Self.confidenceThresholdDefaultsKey)
            return min(max(raw, 0.0), 1.0)
        }()

        isGloballyEnabled = resolvedGloballyEnabled
        disabledAppRules = resolvedDisabledAppRules
        selectedIndicatorMode = resolvedIndicatorMode
        customSuggestionTextColorHex = resolvedCustomSuggestionTextColorHex
        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        selectedLocalPromptMode = resolvedLocalPromptMode
        customAIInstructions = resolvedCustomAIInstructions
        isFirstTokenGatingEnabled = resolvedFirstTokenGatingEnabled
        isFirstTokenConfidenceGatingEnabled = resolvedConfidenceGatingEnabled
        firstTokenConfidenceThreshold = resolvedConfidenceThreshold

        userDefaults.set(resolvedGloballyEnabled, forKey: Self.isGloballyEnabledDefaultsKey)
        persistDisabledAppRules(resolvedDisabledAppRules)
        persistSelectedIndicatorMode(resolvedIndicatorMode)
        persistCustomSuggestionTextColorHex(resolvedCustomSuggestionTextColorHex)
        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistSelectedLocalPromptMode(resolvedLocalPromptMode)
        persistCustomAIInstructions(resolvedCustomAIInstructions)
        userDefaults.set(resolvedFirstTokenGatingEnabled, forKey: Self.isFirstTokenGatingEnabledDefaultsKey)
        userDefaults.set(resolvedConfidenceGatingEnabled, forKey: Self.confidenceGatingEnabledDefaultsKey)
        userDefaults.set(resolvedConfidenceThreshold, forKey: Self.confidenceThresholdDefaultsKey)
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
            disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            effectivePromptMode: effectivePromptMode,
            customAIInstructions: CustomAIInstructionFormatter.normalized(customAIInstructions),
            isFirstTokenGatingEnabled: isFirstTokenGatingEnabled,
            isFirstTokenConfidenceGatingEnabled: isFirstTokenConfidenceGatingEnabled,
            firstTokenConfidenceThreshold: firstTokenConfidenceThreshold
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

    func setGloballyEnabled(_ enabled: Bool) {
        guard isGloballyEnabled != enabled else {
            return
        }

        isGloballyEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isGloballyEnabledDefaultsKey)
    }

    func setApplicationDisabled(
        bundleIdentifier: String?,
        displayName: String,
        disabled: Bool
    ) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        if disabled {
            disableApplication(
                bundleIdentifier: normalizedBundleIdentifier,
                displayName: displayName
            )
        } else {
            removeDisabledApplication(bundleIdentifier: normalizedBundleIdentifier)
        }
    }

    func disableApplication(
        bundleIdentifier: String,
        displayName: String
    ) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) else {
            return
        }

        let normalizedDisplayName = Self.normalizedDisplayName(
            displayName,
            fallbackBundleIdentifier: normalizedBundleIdentifier
        )
        let rule = DisabledApplicationRule(
            bundleIdentifier: normalizedBundleIdentifier,
            displayName: normalizedDisplayName
        )
        var updatedRulesByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: disabledAppRules.map { ($0.bundleIdentifier, $0) }
        )
        updatedRulesByBundleIdentifier[normalizedBundleIdentifier] = rule
        let updatedRules = Self.sortedDisabledAppRules(Array(updatedRulesByBundleIdentifier.values))

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        persistDisabledAppRules(updatedRules)
    }

    func removeDisabledApplication(bundleIdentifier: String?) {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        else {
            return
        }

        let updatedRules = disabledAppRules.filter {
            $0.bundleIdentifier != normalizedBundleIdentifier
        }

        guard disabledAppRules != updatedRules else {
            return
        }

        disabledAppRules = updatedRules
        persistDisabledAppRules(updatedRules)
    }

    func isApplicationDisabled(bundleIdentifier: String?) -> Bool {
        guard let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        else {
            return false
        }

        return disabledAppRules.contains {
            $0.bundleIdentifier == normalizedBundleIdentifier
        }
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

    func setFirstTokenGatingEnabled(_ enabled: Bool) {
        guard isFirstTokenGatingEnabled != enabled else {
            return
        }

        isFirstTokenGatingEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isFirstTokenGatingEnabledDefaultsKey)
    }

    func setFirstTokenConfidenceGatingEnabled(_ enabled: Bool) {
        guard isFirstTokenConfidenceGatingEnabled != enabled else {
            return
        }

        isFirstTokenConfidenceGatingEnabled = enabled
        userDefaults.set(enabled, forKey: Self.confidenceGatingEnabledDefaultsKey)
    }

    func setFirstTokenConfidenceThreshold(_ threshold: Double) {
        // Clamp at the setter boundary so any UI bug (slider out of range, manual defaults edit)
        // cannot corrupt persisted state. The runtime layer trusts this value as already-valid.
        let clamped = min(max(threshold, 0.0), 1.0)
        guard firstTokenConfidenceThreshold != clamped else {
            return
        }

        firstTokenConfidenceThreshold = clamped
        userDefaults.set(clamped, forKey: Self.confidenceThresholdDefaultsKey)
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

    private static func loadDisabledAppRules(from userDefaults: UserDefaults) -> [DisabledApplicationRule] {
        guard let data = userDefaults.data(forKey: Self.disabledAppRulesDefaultsKey),
              let decodedRules = try? JSONDecoder().decode([DisabledApplicationRule].self, from: data)
        else {
            return []
        }

        return sanitizedDisabledAppRules(decodedRules)
    }

    private static func sanitizedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        var rulesByBundleIdentifier: [String: DisabledApplicationRule] = [:]

        for rule in rules {
            guard let normalizedBundleIdentifier = normalizedBundleIdentifier(rule.bundleIdentifier)
            else {
                continue
            }

            rulesByBundleIdentifier[normalizedBundleIdentifier] = DisabledApplicationRule(
                bundleIdentifier: normalizedBundleIdentifier,
                displayName: normalizedDisplayName(
                    rule.displayName,
                    fallbackBundleIdentifier: normalizedBundleIdentifier
                )
            )
        }

        return sortedDisabledAppRules(Array(rulesByBundleIdentifier.values))
    }

    private static func sortedDisabledAppRules(
        _ rules: [DisabledApplicationRule]
    ) -> [DisabledApplicationRule] {
        rules.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }

            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else {
            return nil
        }

        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedDisplayName(
        _ displayName: String,
        fallbackBundleIdentifier: String
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackBundleIdentifier : trimmed
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

    private func persistDisabledAppRules(_ rules: [DisabledApplicationRule]) {
        guard !rules.isEmpty else {
            userDefaults.removeObject(forKey: Self.disabledAppRulesDefaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: Self.disabledAppRulesDefaultsKey)
        }
    }
}

extension SuggestionSettingsModel: SuggestionSettingsProviding {
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        // Combine maxes out at four upstreams per operator, but the snapshot now depends on nine
        // published values. We split them into two logical bundles — a "core" group of always-on
        // selections and a "first-token" group of llama-only gating settings — then CombineLatest
        // those two intermediate publishers. Equality on the bundles via removeDuplicates makes
        // the downstream snapshot still emit only on real change.
        let coreSelections = Publishers.CombineLatest4(
            Publishers.CombineLatest4(
                $isGloballyEnabled,
                $disabledAppRules,
                $selectedEngine,
                $selectedWordCountPreset
            ),
            $selectedLocalPromptMode,
            $customAIInstructions,
            $isFirstTokenGatingEnabled
        )

        let confidenceSelections = Publishers.CombineLatest(
            $isFirstTokenConfidenceGatingEnabled,
            $firstTokenConfidenceThreshold
        )

        return Publishers.CombineLatest(coreSelections, confidenceSelections)
            .map { coreTuple, confidenceTuple in
                let (combinedSettings, localPromptMode, customAIInstructions, firstTokenGatingEnabled) = coreTuple
                let (globallyEnabled, disabledAppRules, engine, wordCountPreset) = combinedSettings
                let (confidenceGatingEnabled, confidenceThreshold) = confidenceTuple
                return SuggestionSettingsSnapshot(
                    isGloballyEnabled: globallyEnabled,
                    disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
                    selectedEngine: engine,
                    selectedWordCountPreset: wordCountPreset,
                    effectivePromptMode: Self.effectivePromptMode(
                        engine: engine,
                        localPromptMode: localPromptMode
                    ),
                    customAIInstructions: CustomAIInstructionFormatter.normalized(customAIInstructions),
                    isFirstTokenGatingEnabled: firstTokenGatingEnabled,
                    isFirstTokenConfidenceGatingEnabled: confidenceGatingEnabled,
                    firstTokenConfidenceThreshold: confidenceThreshold
                )
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
