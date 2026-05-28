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
}
