import Foundation

/// A per-app choice that can follow the global setting or force it on or off. Mirrors the
/// "Default (on) / On / Off" pickers users know from the Apps pane.
nonisolated enum PerAppToggle: String, Codable, CaseIterable, Equatable, Sendable {
    case useDefault
    case on
    case off

    /// Applies the choice over the global value.
    func resolve(default globalValue: Bool) -> Bool {
        switch self {
        case .useDefault: return globalValue
        case .on: return true
        case .off: return false
        }
    }
}

/// App-specific suggestion behavior stored on that app's `PerAppShortcutOverride` record.
///
/// Why it lives there: Cotabby already keeps one persisted, published record per configured app for
/// its accept keys. Putting behavior on the same record keeps every per-app choice in one place, so
/// removing an app from the Apps pane removes all of its overrides together, and old saved records
/// (without this field) still decode. Completions on/off is not here because the disabled-apps list
/// already owns it; typing-history collection is not here because `TypingHistoryStore` owns it.
nonisolated struct PerAppBehavior: Codable, Equatable, Sendable {
    /// Same cap as global Extended Context: these notes join it in the same prompt section.
    static let maximumInstructionCharacters = 1_200

    /// Whether new suggestions may start while text follows the caret on the same line.
    var midLineCompletions: PerAppToggle = .useDefault
    /// Whether the typo gate (hide completions on a typo, offer and auto-apply corrections) runs.
    var autocorrect: PerAppToggle = .useDefault
    /// Notes added to Extended Context only while typing in this app.
    var instructions: String = ""

    var isEmpty: Bool {
        midLineCompletions == .useDefault && autocorrect == .useDefault
            && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
