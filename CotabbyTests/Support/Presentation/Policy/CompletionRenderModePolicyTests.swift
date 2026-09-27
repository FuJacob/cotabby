import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks in the auto/explicit-preference rules so a regression in the policy is loud rather than
/// a silent UX change. The policy is pure, so these tests do not touch AppKit.
///
/// The rules, in order: a per-app override (when the bundle is known) replaces the global
/// preference; `.auto` maps caret quality to a mode; and finally any *inline* result for a caret
/// parked mid-line is promoted to the card, because inline ghost text would paint over the
/// characters after the caret. Results already routed to the card keep their more specific reason.
final class CompletionRenderModePolicyTests: XCTestCase {

    private struct Case {
        let label: String
        let preference: MirrorPreference
        var overrides: [String: MirrorPreference] = [:]
        var bundle: String? = "com.apple.TextEdit"
        let quality: CaretGeometryQuality
        var atEndOfLine = true
        let expected: CompletionRenderMode
    }

    private func assertModes(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for testCase in cases {
            let policy = CompletionRenderModePolicy(
                userPreference: testCase.preference,
                perAppOverrides: testCase.overrides
            )
            let geometry = CotabbyTestFixtures.overlayGeometry(
                caretQuality: testCase.quality,
                isCaretAtEndOfLine: testCase.atEndOfLine
            )
            XCTAssertEqual(
                policy.mode(for: geometry, bundleIdentifier: testCase.bundle),
                testCase.expected,
                testCase.label,
                file: file,
                line: line
            )
        }
    }

    func test_auto_mapsCaretQualityToMode() {
        // `.exact` and `.derived` land close enough to paint inline (Gmail, Outlook, and Discord's
        // text-marker path are `.derived` and render fine). Both estimate qualities go to the card:
        // good enough to place a popup, not to paint glyphs the eye compares against host text.
        assertModes([
            Case(label: "exact", preference: .auto, quality: .exact, expected: .inline),
            Case(label: "derived", preference: .auto, quality: .derived, expected: .inline),
            Case(label: "estimated", preference: .auto, quality: .estimated,
                 expected: .mirror(reason: .caretGeometryEstimated)),
            Case(label: "layout-estimated", preference: .auto, quality: .layoutEstimated,
                 expected: .mirror(reason: .caretLayoutEstimated))
        ])
    }

    func test_explicitPreferencesIgnoreCaretQualityAtEndOfLine() {
        assertModes([
            Case(label: "always inline, estimated", preference: .alwaysInline, bundle: nil,
                 quality: .estimated, expected: .inline),
            Case(label: "always inline, layout-estimated", preference: .alwaysInline, bundle: nil,
                 quality: .layoutEstimated, expected: .inline),
            Case(label: "always mirror, exact", preference: .alwaysMirror, bundle: nil,
                 quality: .exact, expected: .mirror(reason: .userPreference)),
            Case(label: "always mirror, estimated", preference: .alwaysMirror, bundle: nil,
                 quality: .estimated, expected: .mirror(reason: .userPreference))
        ])
    }

    func test_perAppOverridesReplaceTheGlobalPreferenceOnlyForTheirBundle() {
        let quirky = "com.example.QuirkyApp"
        assertModes([
            Case(label: "override forces mirror over auto", preference: .auto,
                 overrides: [quirky: .alwaysMirror], bundle: quirky, quality: .exact,
                 expected: .mirror(reason: .perAppOverride)),
            Case(label: "other bundles keep the global rule", preference: .auto,
                 overrides: [quirky: .alwaysMirror], bundle: "com.apple.TextEdit", quality: .exact,
                 expected: .inline),
            // Some hosts fall into `.estimated` but still render inline correctly, so users can opt
            // out of the promotion per app.
            Case(label: "override forces inline over the estimated trigger", preference: .auto,
                 overrides: [quirky: .alwaysInline], bundle: quirky, quality: .estimated,
                 expected: .inline),
            Case(label: "override back to auto undoes a global mirror pin", preference: .alwaysMirror,
                 overrides: [quirky: .auto], bundle: quirky, quality: .exact,
                 expected: .inline),
            Case(label: "global mirror for an unlisted bundle is a user-preference reason",
                 preference: .alwaysMirror, overrides: [quirky: .alwaysInline],
                 bundle: "com.apple.TextEdit", quality: .exact,
                 expected: .mirror(reason: .userPreference)),
            Case(label: "a nil bundle can only use the global preference", preference: .alwaysMirror,
                 overrides: [quirky: .alwaysInline], bundle: nil, quality: .exact,
                 expected: .mirror(reason: .userPreference))
        ])
    }

    func test_midLineCaretPromotesOnlyInlineResultsToTheCard() {
        let pinned = "com.example.InlinePinned"
        assertModes([
            Case(label: "auto exact", preference: .auto, quality: .exact, atEndOfLine: false,
                 expected: .mirror(reason: .caretMidLine)),
            Case(label: "auto derived", preference: .auto, quality: .derived, atEndOfLine: false,
                 expected: .mirror(reason: .caretMidLine)),
            // Inline cannot render mid-line at all, so the promotion overrides explicit inline pins.
            Case(label: "global inline pin", preference: .alwaysInline, bundle: nil, quality: .exact,
                 atEndOfLine: false, expected: .mirror(reason: .caretMidLine)),
            Case(label: "per-app inline pin", preference: .auto, overrides: [pinned: .alwaysInline],
                 bundle: pinned, quality: .exact, atEndOfLine: false,
                 expected: .mirror(reason: .caretMidLine)),
            // Already a card: the more specific original reason is retained, never relabeled.
            Case(label: "auto estimated", preference: .auto, quality: .estimated, atEndOfLine: false,
                 expected: .mirror(reason: .caretGeometryEstimated)),
            Case(label: "auto layout-estimated", preference: .auto, quality: .layoutEstimated,
                 atEndOfLine: false, expected: .mirror(reason: .caretLayoutEstimated)),
            Case(label: "global mirror pin", preference: .alwaysMirror, bundle: nil, quality: .exact,
                 atEndOfLine: false, expected: .mirror(reason: .userPreference)),
            Case(label: "per-app mirror pin", preference: .auto, overrides: [pinned: .alwaysMirror],
                 bundle: pinned, quality: .exact, atEndOfLine: false,
                 expected: .mirror(reason: .perAppOverride))
        ])
    }

    func test_defaultPolicyIsAutoWithNoOverrides() {
        let policy = CompletionRenderModePolicy()

        XCTAssertEqual(policy, CompletionRenderModePolicy(userPreference: .auto, perAppOverrides: [:]))
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
