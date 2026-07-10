import CoreGraphics
import Foundation

/// File overview:
/// Pure, event-time resolution of which `(keyCode, modifiers)` pair should be treated as the
/// accept-word (or accept-full) shortcut for the currently-focused app.
///
/// **Precedence (highest first):**
/// 1. **Per-app override** — `PerAppShortcutOverride` matching the frontmost bundle id.
/// 2. **Global binding** — `SuggestionSettingsModel.acceptanceKey*` /
///    `SuggestionSettingsModel.fullAcceptanceKey*`.
///
/// This file is the single source of truth for that ordering. The resolver is intentionally a
/// pure free function (no event tap, no AX) so the matrix can be unit-tested without launching
/// the app — the input-monitor providers in `CotabbyAppEnvironment` call into it once per
/// keystroke with the current frontmost bundle id from `FocusTrackingModel.snapshot`.
enum ShortcutResolver {
    struct ResolvedBinding: Equatable {
        let keyCode: CGKeyCode
        let modifiers: ShortcutModifierMask
        /// User-facing label that should appear in the keycap hint, recorder badge, etc. When
        /// the resolved binding came from an override this is the per-app label; otherwise it is
        /// the global label so the pill still teaches the key that will actually fire.
        let label: String
    }

    /// Resolve the accept-word binding for `frontmostBundleIdentifier`.
    ///
    /// - Parameters:
    ///   - frontmostBundleIdentifier: bundle id from `FocusTrackingModel.snapshot`. Resolution
    ///     runs at event time on the closure path, so this is intentionally read fresh per call
    ///     rather than captured.
    ///   - overrides: live list from `SuggestionSettingsModel.perAppShortcutOverrides`. Same
    ///     event-time-fresh requirement.
    ///   - globalKeyCode/Modifiers/Label: the global accept-word binding.
    /// - Returns: the override binding when one is present for the frontmost app, else the
    ///   global binding. Disabled-sentinel keys (`SuggestionSettingsModel.disabledKeyCode`) are
    ///   returned verbatim — choosing "no key" for one app is a legitimate override, not a
    ///   reason to inherit.
    static func acceptBinding(
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        globalKeyCode: CGKeyCode,
        globalModifiers: ShortcutModifierMask,
        globalLabel: String
    ) -> ResolvedBinding {
        if let override = override(for: frontmostBundleIdentifier, in: overrides),
           let keyCode = override.acceptKeyCode,
           let modifiers = override.acceptKeyModifiers,
           let label = override.acceptKeyLabel {
            return ResolvedBinding(keyCode: keyCode, modifiers: modifiers, label: label)
        }
        return ResolvedBinding(keyCode: globalKeyCode, modifiers: globalModifiers, label: globalLabel)
    }

    /// Mirror of `acceptBinding` for the full-accept (accept-entire-suggestion) action.
    static func fullAcceptBinding(
        frontmostBundleIdentifier: String?,
        overrides: [PerAppShortcutOverride],
        globalKeyCode: CGKeyCode,
        globalModifiers: ShortcutModifierMask,
        globalLabel: String
    ) -> ResolvedBinding {
        if let override = override(for: frontmostBundleIdentifier, in: overrides),
           let keyCode = override.fullAcceptKeyCode,
           let modifiers = override.fullAcceptKeyModifiers,
           let label = override.fullAcceptKeyLabel {
            return ResolvedBinding(keyCode: keyCode, modifiers: modifiers, label: label)
        }
        return ResolvedBinding(keyCode: globalKeyCode, modifiers: globalModifiers, label: globalLabel)
    }

    /// Linear lookup. `overrides` is small (one row per customized app), so a Dictionary is
    /// not worth the per-mutation allocation; a fresh array is published on every change.
    private static func override(
        for bundleIdentifier: String?,
        in overrides: [PerAppShortcutOverride]
    ) -> PerAppShortcutOverride? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return overrides.first { $0.bundleIdentifier == bundleIdentifier }
    }
}
