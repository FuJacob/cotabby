import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks in the auto/explicit-preference rules so a regression in the policy is loud rather than
/// a silent UX change. The policy is pure, so these tests do not touch AppKit.
final class CompletionRenderModePolicyTests: XCTestCase {

    // MARK: - Auto preference (Phase 1 default)

    func test_auto_returnsInlineForExactCaretGeometry() {
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .exact)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.apple.TextEdit"),
            .inline
        )
    }

    func test_auto_returnsInlineForDerivedCaretGeometry() {
        // `.derived` is intentionally NOT a mirror trigger. Cotypist-equivalent hosts (Gmail,
        // Outlook, Discord via text marker) land on `.derived` today and render fine inline.
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .derived)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.google.Chrome"),
            .inline
        )
    }

    func test_auto_returnsMirrorForEstimatedCaretGeometry() {
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .estimated)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.microsoft.VSCode"),
            .mirror(reason: .caretGeometryEstimated)
        )
    }

    // MARK: - Always-inline preference

    func test_alwaysInline_keepsInlineEvenForEstimatedGeometry() {
        let policy = CompletionRenderModePolicy(userPreference: .alwaysInline)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .estimated)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: nil),
            .inline
        )
    }

    // MARK: - Always-mirror preference

    func test_alwaysMirror_returnsMirrorWithUserPreferenceReason() {
        let policy = CompletionRenderModePolicy(userPreference: .alwaysMirror)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .exact)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: nil),
            .mirror(reason: .userPreference)
        )
    }

    // MARK: - Per-app overrides

    func test_perAppOverride_winsOverGlobalAutoPreference() {
        // Auto would say inline for `.exact`, but the per-app override forces mirror.
        let policy = CompletionRenderModePolicy(
            userPreference: .auto,
            perAppOverrides: ["com.example.QuirkyApp": .alwaysMirror]
        )
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .exact)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.example.QuirkyApp"),
            .mirror(reason: .perAppOverride)
        )
    }

    func test_perAppOverride_doesNotAffectOtherApps() {
        let policy = CompletionRenderModePolicy(
            userPreference: .auto,
            perAppOverrides: ["com.example.QuirkyApp": .alwaysMirror]
        )
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .exact)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.apple.TextEdit"),
            .inline
        )
    }

    func test_perAppOverride_canForceInlineForKnownGoodApp() {
        // The estimated-geometry trigger should be overridable — some apps fall into estimated but
        // still render inline ghost text correctly, and users should be able to opt out of the
        // promotion.
        let policy = CompletionRenderModePolicy(
            userPreference: .auto,
            perAppOverrides: ["com.example.WeirdGeometry": .alwaysInline]
        )
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .estimated)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.example.WeirdGeometry"),
            .inline
        )
    }

    // MARK: - Nil bundle identifier

    func test_nilBundleIdentifier_fallsBackToUserPreference() {
        let policy = CompletionRenderModePolicy(
            userPreference: .alwaysMirror,
            perAppOverrides: ["com.example.AnyApp": .alwaysInline]
        )
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .exact)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: nil),
            .mirror(reason: .userPreference)
        )
    }

    // MARK: - Mid-line caret promotion

    func test_auto_midLineCaret_promotesExactGeometryToMirror() {
        // Exact geometry renders inline at end of line, but a caret with real characters after it has
        // no inline home (the ghost would paint over the trailing text), so it promotes to the card.
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .exact,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.apple.TextEdit"),
            .mirror(reason: .caretMidLine)
        )
    }

    func test_auto_midLineCaret_promotesDerivedGeometryToMirror() {
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .derived,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.google.Chrome"),
            .mirror(reason: .caretMidLine)
        )
    }

    func test_auto_midLineCaret_keepsEstimatedReasonRatherThanOverwriting() {
        // Estimated geometry already routes to the card; the promotion only upgrades inline results,
        // so the more specific geometry reason is retained instead of being relabeled mid-line.
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .estimated,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.microsoft.VSCode"),
            .mirror(reason: .caretGeometryEstimated)
        )
    }

    func test_alwaysInline_midLineCaret_isOverriddenToMirror() {
        // Inline cannot render mid-line, so the mid-line rule overrides even an explicit inline pin.
        // At the end of a line the pin is still honored (see the next test).
        let policy = CompletionRenderModePolicy(userPreference: .alwaysInline)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .exact,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: nil),
            .mirror(reason: .caretMidLine)
        )
    }

    func test_alwaysInline_endOfLineCaret_staysInline() {
        let policy = CompletionRenderModePolicy(userPreference: .alwaysInline)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .exact,
            isCaretAtEndOfLine: true
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: nil),
            .inline
        )
    }

    func test_alwaysMirror_midLineCaret_keepsUserPreferenceReason() {
        // Already a card; the promotion never runs, so the user-preference reason is preserved.
        let policy = CompletionRenderModePolicy(userPreference: .alwaysMirror)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .exact,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: nil),
            .mirror(reason: .userPreference)
        )
    }

    func test_perAppInlineOverride_midLineCaret_isOverriddenToMirror() {
        // A per-app inline override is still a request to render inline, which mid-line can't honor.
        let policy = CompletionRenderModePolicy(
            userPreference: .auto,
            perAppOverrides: ["com.example.InlinePinned": .alwaysInline]
        )
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .exact,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.example.InlinePinned"),
            .mirror(reason: .caretMidLine)
        )
    }

    // MARK: - Layout-estimated geometry (caret layout repair)

    func test_auto_returnsInlineForLayoutEstimatedCaretGeometry() {
        // `.layoutEstimated` only exists when the caret layout repair accepted a hidden-text-layout
        // estimate; rendering inline on that estimate is the entire point of the repair.
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretQuality: .layoutEstimated)

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.microsoft.VSCode"),
            .inline
        )
    }

    func test_auto_midLineCaret_promotesLayoutEstimatedGeometryToMirror() {
        // The repair fixes geometry, not the mid-line rule: characters after the caret still have
        // no inline home, so the card promotion applies to repaired geometry too.
        let policy = CompletionRenderModePolicy(userPreference: .auto)
        let geometry = CotabbyTestFixtures.overlayGeometry(
            caretQuality: .layoutEstimated,
            isCaretAtEndOfLine: false
        )

        XCTAssertEqual(
            policy.mode(for: geometry, bundleIdentifier: "com.microsoft.VSCode"),
            .mirror(reason: .caretMidLine)
        )
    }

    // MARK: - User-facing preference metadata

    func test_mirrorPreference_displayLabelsUseProductVocabulary() {
        // The policy is the single source of truth for the Settings copy: "mirror" is internal
        // naming, the user-facing word is "Popup".
        XCTAssertEqual(MirrorPreference.auto.displayLabel, "Auto")
        XCTAssertEqual(MirrorPreference.alwaysInline.displayLabel, "Inline")
        XCTAssertEqual(MirrorPreference.alwaysMirror.displayLabel, "Popup")
    }

    func test_mirrorPreference_identifiableIdIsTheRawValue() {
        for preference in MirrorPreference.allCases {
            XCTAssertEqual(preference.id, preference.rawValue)
        }
    }
}
