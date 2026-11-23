import CoreGraphics
import Foundation

/// Resolves the effective accept binding for the focused app. A matching per-app value wins;
/// otherwise the global binding is returned.
enum ShortcutResolver {
    struct ResolvedBinding: Equatable {
        let keyCode: CGKeyCode
        let modifiers: ShortcutModifierMask
        let label: String
    }

    static func acceptBinding(
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        globalKeyCode: CGKeyCode,
        globalModifiers: ShortcutModifierMask,
        globalLabel: String
    ) -> ResolvedBinding {
        resolve(
            \.acceptance,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            overrides: overrides,
            global: ResolvedBinding(keyCode: globalKeyCode, modifiers: globalModifiers, label: globalLabel)
        )
    }

    static func fullAcceptBinding(
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        globalKeyCode: CGKeyCode,
        globalModifiers: ShortcutModifierMask,
        globalLabel: String
    ) -> ResolvedBinding {
        resolve(
            \.fullAcceptance,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            overrides: overrides,
            global: ResolvedBinding(keyCode: globalKeyCode, modifiers: globalModifiers, label: globalLabel)
        )
    }

    /// One precedence rule for both accept actions, so a per-app slot can never be honored for one
    /// action and ignored for the other.
    private static func resolve(
        _ slot: KeyPath<PerAppShortcutOverride, SuggestionShortcutBindingSettings?>,
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        global: ResolvedBinding
    ) -> ResolvedBinding {
        guard let binding = override(for: frontmostBundleIdentifier, in: overrides)?[keyPath: slot] else {
            return global
        }
        return ResolvedBinding(keyCode: binding.keyCode, modifiers: binding.modifiers, label: binding.label)
    }

    private static func override(
        for bundleIdentifier: String?,
        in overrides: [PerAppShortcutOverride]
    ) -> PerAppShortcutOverride? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return overrides.first { $0.bundleIdentifier == bundleIdentifier }
    }
}
