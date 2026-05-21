import Combine
import Foundation

/// File overview:
/// Owns the durable autocomplete preferences that are shared across the app:
/// engine selection, completion length, indicator appearance, and profile
/// personalization.
///
/// This type is the right owner for these values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var isGloballyEnabled: Bool
    @Published private(set) var showIndicator: Bool
    @Published private(set) var disabledAppRules: [DisabledApplicationRule]
    @Published private(set) var customSuggestionTextColorHex: String?
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var isClipboardContextEnabled: Bool
    @Published private(set) var userName: String
    @Published private(set) var debounceMilliseconds: Int
    @Published private(set) var focusPollIntervalMilliseconds: Int
    private let userDefaults: UserDefaults

    private static let isGloballyEnabledDefaultsKey = "tabbyGloballyEnabled"
    private static let disabledAppRulesDefaultsKey = "tabbyDisabledAppRules"
    // Legacy key. Keep reading and writing through it so old builds degrade to a visible indicator.
    private static let showCaretIndicatorDefaultsKey = "tabbyShowCaretIndicator"
    private static let selectedIndicatorModeDefaultsKey = "tabbySelectedIndicatorMode"
    private static let customSuggestionTextColorHexDefaultsKey = "tabbyCustomSuggestionTextColorHex"
    private static let selectedEngineDefaultsKey = "selectedSuggestionEngine"
    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let clipboardContextEnabledDefaultsKey = "tabbyClipboardContextEnabled"
    private static let userNameDefaultsKey = "tabbyUserName"
    private static let debounceMillisecondsDefaultsKey = "tabbyDebounceMilliseconds"
    private static let focusPollIntervalMillisecondsDefaultsKey = "tabbyFocusPollIntervalMilliseconds"

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let resolvedDisabledAppRules = Self.loadDisabledAppRules(from: userDefaults)
        let resolvedShowIndicator: Bool = if let modeString = userDefaults.string(
            forKey: Self.selectedIndicatorModeDefaultsKey
        ) {
            modeString != ActivationIndicatorMode.hidden.rawValue
        } else {
            userDefaults.object(forKey: Self.showCaretIndicatorDefaultsKey) as? Bool ?? true
        }
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
        let resolvedClipboardContextEnabled =
            userDefaults.object(forKey: Self.clipboardContextEnabledDefaultsKey) as? Bool ?? true
        let resolvedUserName: String = if userDefaults.object(forKey: Self.userNameDefaultsKey) == nil {
            configuration.defaultUserName ?? ""
        } else {
            userDefaults.string(forKey: Self.userNameDefaultsKey) ?? ""
        }

        let resolvedDebounceMilliseconds: Int = {
            let raw = userDefaults.object(forKey: Self.debounceMillisecondsDefaultsKey) as? Int
                ?? configuration.debounceMilliseconds
            return max(10, min(500, raw))
        }()
        let resolvedFocusPollIntervalMilliseconds: Int = {
            let raw = userDefaults.object(forKey: Self.focusPollIntervalMillisecondsDefaultsKey) as? Int
                ?? configuration.focusPollIntervalMilliseconds
            return max(10, min(500, raw))
        }()

        isGloballyEnabled = resolvedGloballyEnabled
        disabledAppRules = resolvedDisabledAppRules
        showIndicator = resolvedShowIndicator
        customSuggestionTextColorHex = resolvedCustomSuggestionTextColorHex
        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        isClipboardContextEnabled = resolvedClipboardContextEnabled
        userName = resolvedUserName
        debounceMilliseconds = resolvedDebounceMilliseconds
        focusPollIntervalMilliseconds = resolvedFocusPollIntervalMilliseconds

        userDefaults.set(resolvedGloballyEnabled, forKey: Self.isGloballyEnabledDefaultsKey)
        persistDisabledAppRules(resolvedDisabledAppRules)
        persistShowIndicator(resolvedShowIndicator)
        persistCustomSuggestionTextColorHex(resolvedCustomSuggestionTextColorHex)
        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistClipboardContextEnabled(resolvedClipboardContextEnabled)
        persistUserName(resolvedUserName)
        userDefaults.set(resolvedDebounceMilliseconds, forKey: Self.debounceMillisecondsDefaultsKey)
        userDefaults.set(resolvedFocusPollIntervalMilliseconds, forKey: Self.focusPollIntervalMillisecondsDefaultsKey)
    }

    /// Legacy compatibility shim. Reads through to `showIndicator`.
    var showCaretIndicator: Bool {
        showIndicator
    }

    var snapshot: SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: isGloballyEnabled,
            disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            isClipboardContextEnabled: isClipboardContextEnabled,
            userName: userName,
            debounceMilliseconds: debounceMilliseconds,
            focusPollIntervalMilliseconds: focusPollIntervalMilliseconds
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

    func setClipboardContextEnabled(_ enabled: Bool) {
        guard isClipboardContextEnabled != enabled else {
            return
        }

        isClipboardContextEnabled = enabled
        persistClipboardContextEnabled(enabled)
    }

    func setDebounceMilliseconds(_ value: Int) {
        let clamped = max(10, min(500, value))
        guard debounceMilliseconds != clamped else {
            return
        }

        debounceMilliseconds = clamped
        userDefaults.set(clamped, forKey: Self.debounceMillisecondsDefaultsKey)
    }

    func setFocusPollIntervalMilliseconds(_ value: Int) {
        let clamped = max(10, min(500, value))
        guard focusPollIntervalMilliseconds != clamped else {
            return
        }

        focusPollIntervalMilliseconds = clamped
        userDefaults.set(clamped, forKey: Self.focusPollIntervalMillisecondsDefaultsKey)
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

    func setShowIndicator(_ show: Bool) {
        guard showIndicator != show else {
            return
        }

        showIndicator = show
        persistShowIndicator(show)
    }

    func setCustomSuggestionTextColorHex(_ hex: String?) {
        let normalizedHex = Self.normalizedHexString(hex)
        guard customSuggestionTextColorHex != normalizedHex else {
            return
        }

        customSuggestionTextColorHex = normalizedHex
        persistCustomSuggestionTextColorHex(normalizedHex)
    }

    func setUserName(_ name: String) {
        guard userName != name else {
            return
        }

        userName = name
        persistUserName(name)
    }

    private func persistSelectedEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.selectedEngineDefaultsKey)
    }

    private func persistSelectedWordCountPreset(_ preset: SuggestionWordCountPreset) {
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
    }

    private func persistClipboardContextEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.clipboardContextEnabledDefaultsKey)
    }

    private func persistShowIndicator(_ show: Bool) {
        let mode: ActivationIndicatorMode = show ? .fieldEdgeIcon : .hidden
        userDefaults.set(mode.rawValue, forKey: Self.selectedIndicatorModeDefaultsKey)
        userDefaults.set(show, forKey: Self.showCaretIndicatorDefaultsKey)
    }

    private func persistCustomSuggestionTextColorHex(_ hex: String?) {
        if let hex {
            userDefaults.set(hex, forKey: Self.customSuggestionTextColorHexDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.customSuggestionTextColorHexDefaultsKey)
        }
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

    private func persistUserName(_ name: String) {
        userDefaults.set(name, forKey: Self.userNameDefaultsKey)
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
        Publishers.CombineLatest4(
            Publishers.CombineLatest4(
                $isGloballyEnabled,
                $disabledAppRules,
                $selectedEngine,
                $selectedWordCountPreset
            ),
            $isClipboardContextEnabled,
            $userName,
            Publishers.CombineLatest($debounceMilliseconds, $focusPollIntervalMilliseconds)
        )
        .map { combinedSettings, clipboardContextEnabled, userName, timing in
            let (globallyEnabled, disabledAppRules, engine, wordCountPreset) = combinedSettings
            let (debounce, focusPoll) = timing
            return SuggestionSettingsSnapshot(
                isGloballyEnabled: globallyEnabled,
                disabledAppBundleIdentifiers: Set(disabledAppRules.map(\.bundleIdentifier)),
                selectedEngine: engine,
                selectedWordCountPreset: wordCountPreset,
                isClipboardContextEnabled: clipboardContextEnabled,
                userName: userName,
                debounceMilliseconds: debounce,
                focusPollIntervalMilliseconds: focusPoll
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
