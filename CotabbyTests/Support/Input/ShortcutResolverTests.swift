import XCTest
@testable import Cotabby

/// Verifies per-app shortcut precedence independently of the global event tap.
final class ShortcutResolverTests: XCTestCase {
    func test_acceptBinding_fallsBackToGlobalWhenNoOverride() {
        XCTAssertEqual(resolveAccept(), globalAccept)
    }

    func test_acceptBinding_usesOverrideWhenPresent() {
        let resolved = resolveAccept(
            overrides: [makeOverride(acceptance: binding(49, [.shift], "⇧Space"))]
        )

        XCTAssertEqual(resolved, .init(keyCode: 49, modifiers: [.shift], label: "⇧Space"))
    }

    func test_acceptBinding_fullAcceptOverrideDoesNotAffectWordAccept() {
        let resolved = resolveAccept(
            overrides: [makeOverride(fullAcceptance: binding(50, [.shift], "⇧`"))]
        )

        XCTAssertEqual(resolved, globalAccept)
    }

    func test_acceptBinding_doesNotLeakAcrossApps() {
        let resolved = resolveAccept(
            bundleIdentifier: "com.example.other",
            overrides: [makeOverride(acceptance: binding(49, [], "Space"))]
        )

        XCTAssertEqual(resolved, globalAccept)
    }

    func test_acceptBinding_nilBundleIdentifierUsesGlobal() {
        let resolved = resolveAccept(
            bundleIdentifier: nil,
            overrides: [makeOverride(acceptance: binding(49, [], "Space"))]
        )

        XCTAssertEqual(resolved, globalAccept)
    }

    func test_acceptBinding_honorsDisabledOverride() {
        let disabled = binding(
            SuggestionSettingsModel.disabledKeyCode,
            [],
            SuggestionSettingsModel.disabledKeyLabel
        )

        XCTAssertEqual(
            resolveAccept(overrides: [makeOverride(acceptance: disabled)]),
            .init(
                keyCode: SuggestionSettingsModel.disabledKeyCode,
                modifiers: [],
                label: SuggestionSettingsModel.disabledKeyLabel
            )
        )
    }

    func test_fullAcceptBinding_usesOverrideWhenPresent() {
        let resolved = resolveFullAccept(
            overrides: [makeOverride(fullAcceptance: binding(36, [.command], "⌘Return"))]
        )

        XCTAssertEqual(resolved, .init(keyCode: 36, modifiers: [.command], label: "⌘Return"))
    }

    func test_fullAcceptBinding_wordAcceptOverrideDoesNotAffectFullAccept() {
        let resolved = resolveFullAccept(
            overrides: [makeOverride(acceptance: binding(49, [], "Space"))]
        )

        XCTAssertEqual(resolved, globalFullAccept)
    }

    func test_emptyBundleIdentifierNeverMatchesAnOverride() {
        // An empty identifier (no resolvable frontmost app) must not match an override that was
        // somehow stored with an empty identifier.
        let override = PerAppShortcutOverride(
            bundleIdentifier: "",
            displayName: "Unknown",
            acceptance: binding(49, [], "Space"),
            fullAcceptance: binding(36, [], "Return")
        )

        XCTAssertEqual(resolveAccept(bundleIdentifier: "", overrides: [override]), globalAccept)
        XCTAssertEqual(resolveFullAccept(bundleIdentifier: "", overrides: [override]), globalFullAccept)
    }

    func test_firstMatchingOverrideWinsEvenWhenItLacksTheRequestedBinding() {
        // Lookup stops at the first entry for the bundle; a later duplicate is never consulted,
        // so the first entry's missing word-accept binding falls through to the global binding.
        let first = makeOverride(fullAcceptance: binding(36, [.command], "⌘Return"))
        let duplicate = makeOverride(
            acceptance: binding(49, [.shift], "⇧Space"),
            fullAcceptance: binding(50, [.option], "⌥`")
        )

        XCTAssertEqual(resolveAccept(overrides: [first, duplicate]), globalAccept)
        XCTAssertEqual(
            resolveFullAccept(overrides: [first, duplicate]),
            .init(keyCode: 36, modifiers: [.command], label: "⌘Return")
        )
    }

    func test_overrideWithNoBindingsUsesGlobalForBothActions() {
        XCTAssertEqual(resolveAccept(overrides: [makeOverride()]), globalAccept)
        XCTAssertEqual(resolveFullAccept(overrides: [makeOverride()]), globalFullAccept)
    }

    private var globalAccept: ShortcutResolver.ResolvedBinding {
        .init(keyCode: 48, modifiers: [], label: "Tab")
    }

    private var globalFullAccept: ShortcutResolver.ResolvedBinding {
        .init(keyCode: 50, modifiers: [], label: "`")
    }

    private func resolveAccept(
        bundleIdentifier: String? = "com.apple.notes",
        overrides: [PerAppShortcutOverride] = []
    ) -> ShortcutResolver.ResolvedBinding {
        ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: bundleIdentifier,
            overrides: overrides,
            globalKeyCode: globalAccept.keyCode,
            globalModifiers: globalAccept.modifiers,
            globalLabel: globalAccept.label
        )
    }

    private func resolveFullAccept(
        bundleIdentifier: String? = "com.apple.notes",
        overrides: [PerAppShortcutOverride] = []
    ) -> ShortcutResolver.ResolvedBinding {
        ShortcutResolver.fullAcceptBinding(
            frontmostBundleIdentifier: bundleIdentifier,
            overrides: overrides,
            globalKeyCode: globalFullAccept.keyCode,
            globalModifiers: globalFullAccept.modifiers,
            globalLabel: globalFullAccept.label
        )
    }

    private func binding(
        _ keyCode: CGKeyCode,
        _ modifiers: ShortcutModifierMask,
        _ label: String
    ) -> SuggestionShortcutBindingSettings {
        .init(keyCode: keyCode, modifiers: modifiers, label: label)
    }

    private func makeOverride(
        acceptance: SuggestionShortcutBindingSettings? = nil,
        fullAcceptance: SuggestionShortcutBindingSettings? = nil
    ) -> PerAppShortcutOverride {
        .init(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            acceptance: acceptance,
            fullAcceptance: fullAcceptance
        )
    }
}
