import XCTest
@testable import Cotabby

/// Locks down `ShortcutResolver`, the pure function that decides which (keyCode, modifiers, label)
/// fires for the frontmost app. The precedence rule lives in the type doc; these tests pin it.
final class ShortcutResolverTests: XCTestCase {

    // MARK: - Accept (word)

    /// No override for the focused app → resolver falls back to the global accept binding.
    /// This is the most important property: a fresh install with no per-app rows must behave
    /// exactly like the global Shortcuts pane.
    func test_acceptBinding_fallsBackToGlobalWhenNoOverride() {
        let resolved = ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: "com.apple.notes",
            overrides: [],
            globalKeyCode: 48,
            globalModifiers: [],
            globalLabel: "Tab"
        )
        XCTAssertEqual(resolved.keyCode, 48)
        XCTAssertEqual(resolved.modifiers, [])
        XCTAssertEqual(resolved.label, "Tab")
    }

    /// A complete override (all three fields set) takes precedence over the global binding.
    func test_acceptBinding_usesOverrideWhenPresent() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            acceptKeyCode: 49,
            acceptKeyModifiers: [.shift],
            acceptKeyLabel: "⇧Space",
            fullAcceptKeyCode: nil,
            fullAcceptKeyModifiers: nil,
            fullAcceptKeyLabel: nil
        )
        let resolved = ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: "com.apple.notes",
            overrides: [override],
            globalKeyCode: 48,
            globalModifiers: [],
            globalLabel: "Tab"
        )
        XCTAssertEqual(resolved.keyCode, 49)
        XCTAssertEqual(resolved.modifiers, [.shift])
        XCTAssertEqual(resolved.label, "⇧Space")
    }

    /// A *partial* override that has only the full-accept fields set must NOT contaminate the
    /// accept-word resolution — the absent accept-word fields fall back to global.
    /// This is the heart of the "nil-means-inherit" design and the easiest case to get wrong.
    func test_acceptBinding_partialOverrideOnlyAffectsItsOwnAction() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            acceptKeyCode: nil,
            acceptKeyModifiers: nil,
            acceptKeyLabel: nil,
            fullAcceptKeyCode: 50,
            fullAcceptKeyModifiers: [.shift],
            fullAcceptKeyLabel: "⇧`"
        )
        let resolved = ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: "com.apple.notes",
            overrides: [override],
            globalKeyCode: 48,
            globalModifiers: [],
            globalLabel: "Tab"
        )
        XCTAssertEqual(resolved.keyCode, 48)
        XCTAssertEqual(resolved.label, "Tab")
    }

    /// The frontmost bundle id determines which override (if any) wins. A different app's
    /// override must never leak across.
    func test_acceptBinding_doesNotLeakAcrossUnrelatedApps() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes",
            displayName: "Notes",
            acceptKeyCode: 49, acceptKeyModifiers: [], acceptKeyLabel: "Space",
            fullAcceptKeyCode: nil, fullAcceptKeyModifiers: nil, fullAcceptKeyLabel: nil
        )
        let resolved = ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: "com.example.other",
            overrides: [override],
            globalKeyCode: 48, globalModifiers: [], globalLabel: "Tab"
        )
        XCTAssertEqual(resolved.keyCode, 48)
    }

    /// A nil frontmost bundle id (focus snapshot has no app yet) falls through to the global.
    /// Without this property the resolver could misattribute the first keystroke after launch.
    func test_acceptBinding_nilBundleIdResolvesToGlobal() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            acceptKeyCode: 49, acceptKeyModifiers: [], acceptKeyLabel: "Space",
            fullAcceptKeyCode: nil, fullAcceptKeyModifiers: nil, fullAcceptKeyLabel: nil
        )
        let resolved = ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: nil,
            overrides: [override],
            globalKeyCode: 48, globalModifiers: [], globalLabel: "Tab"
        )
        XCTAssertEqual(resolved.keyCode, 48)
        XCTAssertEqual(resolved.label, "Tab")
    }

    /// The disabled sentinel for an override means "no key accepts in this app" — a legitimate
    /// user choice the resolver must honor verbatim, NOT silently inherit the global.
    func test_acceptBinding_honorsDisabledSentinelOverride() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            acceptKeyCode: SuggestionSettingsModel.disabledKeyCode,
            acceptKeyModifiers: [],
            acceptKeyLabel: SuggestionSettingsModel.disabledKeyLabel,
            fullAcceptKeyCode: nil, fullAcceptKeyModifiers: nil, fullAcceptKeyLabel: nil
        )
        let resolved = ShortcutResolver.acceptBinding(
            frontmostBundleIdentifier: "com.apple.notes",
            overrides: [override],
            globalKeyCode: 48, globalModifiers: [], globalLabel: "Tab"
        )
        XCTAssertEqual(resolved.keyCode, SuggestionSettingsModel.disabledKeyCode)
    }

    // MARK: - Full-accept

    /// Mirror property for the full-accept action: override wins when present, otherwise global.
    func test_fullAcceptBinding_usesOverrideWhenPresent() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            acceptKeyCode: nil, acceptKeyModifiers: nil, acceptKeyLabel: nil,
            fullAcceptKeyCode: 36, fullAcceptKeyModifiers: [.command], fullAcceptKeyLabel: "⌘Return"
        )
        let resolved = ShortcutResolver.fullAcceptBinding(
            frontmostBundleIdentifier: "com.apple.notes",
            overrides: [override],
            globalKeyCode: 50, globalModifiers: [], globalLabel: "`"
        )
        XCTAssertEqual(resolved.keyCode, 36)
        XCTAssertEqual(resolved.modifiers, [.command])
        XCTAssertEqual(resolved.label, "⌘Return")
    }

    /// And the inverse: only the accept-word override is set → full-accept still inherits global.
    func test_fullAcceptBinding_inheritsGlobalWhenOnlyAcceptOverrideIsSet() {
        let override = PerAppShortcutOverride(
            bundleIdentifier: "com.apple.notes", displayName: "Notes",
            acceptKeyCode: 49, acceptKeyModifiers: [], acceptKeyLabel: "Space",
            fullAcceptKeyCode: nil, fullAcceptKeyModifiers: nil, fullAcceptKeyLabel: nil
        )
        let resolved = ShortcutResolver.fullAcceptBinding(
            frontmostBundleIdentifier: "com.apple.notes",
            overrides: [override],
            globalKeyCode: 50, globalModifiers: [], globalLabel: "`"
        )
        XCTAssertEqual(resolved.keyCode, 50)
        XCTAssertEqual(resolved.label, "`")
    }
}
