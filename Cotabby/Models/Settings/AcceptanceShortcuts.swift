import CoreGraphics
import Foundation

extension SuggestionShortcutBindingSettings {
    /// "No key". Persisted as the sentinel key code with no modifiers, so an unbound action never
    /// matches a real keyboard event and several actions may be unbound at once.
    static let unbound = SuggestionShortcutBindingSettings(
        keyCode: SuggestionSettingsStore.disabledKeyCode,
        modifiers: [],
        label: SuggestionSettingsStore.disabledKeyLabel
    )

    /// The factory Accept Word key: plain Tab.
    static let defaultAcceptWord = SuggestionShortcutBindingSettings(
        keyCode: SuggestionSettingsStore.defaultAcceptanceKeyCode,
        modifiers: [],
        label: SuggestionSettingsStore.defaultAcceptanceKeyLabel
    )

    /// The factory Accept Entire Suggestion key: plain `` ` ``.
    static let defaultAcceptEntireSuggestion = SuggestionShortcutBindingSettings(
        keyCode: SuggestionSettingsStore.defaultFullAcceptanceKeyCode,
        modifiers: [],
        label: SuggestionSettingsStore.defaultFullAcceptanceKeyLabel
    )

    var isBound: Bool {
        keyCode != SuggestionSettingsStore.disabledKeyCode
    }

    /// Builds the binding to store for a recorded key. Modifiers are dropped when the key is the
    /// unbound sentinel so `(sentinel, [])` is the only spelling of "no key": listeners such as the
    /// global-toggle tap treat that pair as "do not install" without inspecting the modifiers.
    init(recordedKeyCode keyCode: CGKeyCode, modifiers: ShortcutModifierMask, label: String) {
        self.init(
            keyCode: keyCode,
            modifiers: keyCode == SuggestionSettingsStore.disabledKeyCode ? [] : modifiers,
            label: label
        )
    }

    /// Whether this binding fires on the given press. The label is display-only, and an unbound
    /// binding fires on nothing.
    func matches(keyCode: CGKeyCode, modifiers: ShortcutModifierMask) -> Bool {
        isBound && self.keyCode == keyCode && self.modifiers == modifiers
    }
}

extension ShortcutResolver.ResolvedBinding {
    /// False for an app whose override is Disable, or that inherits an unbound global shortcut.
    var isBound: Bool {
        keyCode != SuggestionSettingsStore.disabledKeyCode
    }
}

/// What occupies the Accept Entire Suggestion slot. The slot holds exactly one shortcut, which is
/// why this is an enum rather than a key plus a "double tap" flag: a one-press key and the double
/// tap cannot both be set.
///
/// On disk the slot is still two facts (the one-press key triple and a double-tap flag), which
/// `SuggestionSettingsStore` decodes with `init(keyBinding:doubleTap:)` and re-encodes through
/// `keyBinding` and `isDoubleTap`.
enum FullAcceptanceShortcut: Equatable {
    case unbound
    /// A one-press key. Always a bound binding; "no key" is `.unbound`.
    case key(SuggestionShortcutBindingSettings)
    /// A quick double press of the Accept Word key. It rides on that key, so it is inert while
    /// Accept Word is unbound and follows each app's own Accept Word key.
    case doubleTapOfAcceptWord

    /// Decodes the persisted pair. The double-tap flag wins if both are present, which the
    /// transitions in `AcceptanceShortcuts` never write.
    init(keyBinding: SuggestionShortcutBindingSettings, doubleTap: Bool) {
        if doubleTap {
            self = .doubleTapOfAcceptWord
        } else if keyBinding.isBound {
            self = .key(keyBinding)
        } else {
            self = .unbound
        }
    }

    /// The one-press key to persist and to hand to the input monitor: unbound unless a key holds
    /// the slot, so a double tap never leaves a stale one-press key firing alongside it.
    var keyBinding: SuggestionShortcutBindingSettings {
        if case .key(let binding) = self {
            return binding
        }
        return .unbound
    }

    var isDoubleTap: Bool {
        self == .doubleTapOfAcceptWord
    }
}

/// The Accept Word key and the Accept Entire Suggestion slot, which constrain each other: the two
/// may not share a key, and the double tap exists only as a double press of the Accept Word key.
/// Every edit goes through one of the transitions below, so those rules hold by construction
/// instead of by the order in which setters happen to be called.
struct AcceptanceShortcuts: Equatable {
    var acceptWord: SuggestionShortcutBindingSettings
    var acceptEntireSuggestion: FullAcceptanceShortcut

    // MARK: - Reading

    /// True when the double tap can actually fire: it is bound and there is a key to press twice.
    var isDoubleTapActive: Bool {
        acceptEntireSuggestion.isDoubleTap && acceptWord.isBound
    }

    /// The Accept Entire Suggestion shortcut as users should read it: the one-press key, or the
    /// Accept Word key written twice ("Tab Tab").
    var acceptEntireSuggestionDisplayLabel: String {
        isDoubleTapActive ? "\(acceptWord.label) \(acceptWord.label)" : acceptEntireSuggestion.keyBinding.label
    }

    /// Whether any shortcut accepts the whole suggestion, so views can offer Clear.
    var hasAcceptEntireSuggestionShortcut: Bool {
        isDoubleTapActive || acceptEntireSuggestion.keyBinding.isBound
    }

    /// The key a recorder may take as a double press: the Accept Word key, or `nil` while it is
    /// unbound because there is then nothing to press twice.
    var doubleTapRecordingKey: SuggestionShortcutBindingSettings? {
        acceptWord.isBound ? acceptWord : nil
    }

    /// Whether Accept Word still holds the factory key, so views can hide Reset. The label is
    /// display-only and not compared.
    var isAcceptWordFactoryDefault: Bool {
        let factory = SuggestionShortcutBindingSettings.defaultAcceptWord
        return acceptWord.matches(keyCode: factory.keyCode, modifiers: factory.modifiers)
    }

    /// Whether the slot still holds the factory one-press key, so views can hide Reset.
    var isAcceptEntireSuggestionFactoryDefault: Bool {
        guard case .key(let binding) = acceptEntireSuggestion else {
            return false
        }
        let factory = SuggestionShortcutBindingSettings.defaultAcceptEntireSuggestion
        return binding.matches(keyCode: factory.keyCode, modifiers: factory.modifiers)
    }

    // MARK: - Transitions

    mutating func resetAcceptWord() {
        recordAcceptWord(.defaultAcceptWord)
    }

    mutating func resetAcceptEntireSuggestion() {
        recordAcceptEntireSuggestion(.defaultAcceptEntireSuggestion)
    }

    mutating func recordAcceptWord(_ binding: SuggestionShortcutBindingSettings) {
        guard acceptWord != binding else {
            return
        }
        // Two bindings on the same `(keyCode, modifiers)` would both fire on the same press, so the
        // other side gives way. `Tab` and `⇧Tab` differ in modifiers and may coexist.
        if acceptEntireSuggestion.keyBinding.matches(keyCode: binding.keyCode, modifiers: binding.modifiers) {
            acceptEntireSuggestion = .unbound
        }
        acceptWord = binding
    }

    mutating func clearAcceptWord() {
        // The double tap is a double press of this key, so it goes away with it rather than
        // reappearing unexpectedly when a new Accept Word key is recorded later.
        if acceptEntireSuggestion.isDoubleTap {
            acceptEntireSuggestion = .unbound
        }
        acceptWord = .unbound
    }

    mutating func recordAcceptEntireSuggestion(_ binding: SuggestionShortcutBindingSettings) {
        guard binding.isBound else {
            // Recording "no key" removes a one-press key but is not a request to drop the double tap.
            if case .key = acceptEntireSuggestion {
                acceptEntireSuggestion = .unbound
            }
            return
        }
        guard acceptEntireSuggestion != .key(binding) else {
            return
        }
        if acceptWord.matches(keyCode: binding.keyCode, modifiers: binding.modifiers) {
            clearAcceptWord()
        }
        acceptEntireSuggestion = .key(binding)
    }

    /// Ignored while Accept Word is unbound, since there is no key to press twice.
    mutating func recordDoubleTap() {
        guard acceptWord.isBound else {
            return
        }
        acceptEntireSuggestion = .doubleTapOfAcceptWord
    }

    mutating func clearAcceptEntireSuggestion() {
        acceptEntireSuggestion = .unbound
    }
}
