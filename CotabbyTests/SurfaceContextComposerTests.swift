import XCTest
@testable import Cotabby

/// Locks in the two invariants of surface conditioning: omission beats noise (code editors,
/// terminals, and anonymous generic apps get no section at all), and everything user-derived
/// (titles, placeholders, URLs) is sanitized before it can reach a prompt.
final class SurfaceContextComposerTests: XCTestCase {
    private func compose(
        applicationName: String = "Mail",
        bundleIdentifier: String? = "com.apple.mail",
        isIntegratedTerminal: Bool = false,
        windowTitle: String? = nil,
        focusedURLString: String? = nil,
        fieldPlaceholder: String? = nil
    ) -> SurfaceContext? {
        SurfaceContextComposer.compose(
            surfaceClass: AppSurfaceClassifier.classify(
                bundleIdentifier: bundleIdentifier,
                isIntegratedTerminal: isIntegratedTerminal
            ),
            applicationName: applicationName,
            windowTitle: windowTitle,
            focusedURLString: focusedURLString,
            fieldPlaceholder: fieldPlaceholder
        )
    }

    // MARK: - Class gating

    func testCodeEditorsGetNoSurfaceContext() {
        XCTAssertNil(compose(applicationName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", windowTitle: "Project.swift"))
    }

    func testTerminalsGetNoSurfaceContext() {
        XCTAssertNil(compose(applicationName: "Terminal", bundleIdentifier: "com.apple.Terminal", windowTitle: "zsh"))
        XCTAssertNil(compose(bundleIdentifier: "com.google.Chrome", isIntegratedTerminal: true, windowTitle: "Cloud Shell"))
    }

    func testAnonymousGenericAppIsOmitted() {
        // Unknown app, no title, no domain, no placeholder: nothing useful to say.
        XCTAssertNil(compose(applicationName: "SomeApp", bundleIdentifier: "com.example.someapp"))
    }

    func testGenericAppWithTitleIsIncluded() {
        let surface = compose(
            applicationName: "Bear",
            bundleIdentifier: "net.shinyfrog.bear",
            windowTitle: "Travel plans"
        )
        XCTAssertEqual(surface?.surfaceClass, .other)
        XCTAssertEqual(surface?.windowTitle, "Travel plans")
    }

    // MARK: - Preface lines

    func testEmailPreface() throws {
        let surface = compose(windowTitle: "Re: Q3 budget review")
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: try XCTUnwrap(surface)),
            ["An email being written in Mail.", "The window is titled \"Re: Q3 budget review\"."]
        )
    }

    func testChatPreface() throws {
        let surface = compose(
            applicationName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            fieldPlaceholder: "Message #design"
        )
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: try XCTUnwrap(surface)),
            ["A chat message being typed in Slack.", "The text field is labeled \"Message #design\"."]
        )
    }

    func testBrowserPrefaceUsesDomain() throws {
        let surface = compose(
            applicationName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            focusedURLString: "https://www.notion.so/workspace/page-123"
        )
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: try XCTUnwrap(surface)),
            ["Text being typed on notion.so in Google Chrome."]
        )
    }

    // MARK: - Sanitization

    func testTitleAppNameSuffixIsStripped() {
        XCTAssertEqual(
            SurfaceContextComposer.sanitizedTitle("Inbox (3) - Google Chrome", applicationName: "Google Chrome"),
            "Inbox (3)"
        )
        XCTAssertEqual(
            SurfaceContextComposer.sanitizedTitle("Notes — Pages", applicationName: "Pages"),
            "Notes"
        )
    }

    func testTitleIsCappedAndWhitespaceCollapsed() {
        let long = String(repeating: "title ", count: 40)
        let sanitized = SurfaceContextComposer.sanitizedTitle(long, applicationName: "Mail")
        XCTAssertLessThanOrEqual(sanitized?.count ?? 0, 80)

        XCTAssertEqual(
            SurfaceContextComposer.sanitizedTitle("  Re:\n  budget   review ", applicationName: "Mail"),
            "Re: budget review"
        )
    }

    func testTitleQuotesAndControlCharactersAreDropped() {
        XCTAssertEqual(
            SurfaceContextComposer.sanitizedTitle("Say \"hello\"\u{07} there", applicationName: "Mail"),
            "Say hello there"
        )
    }

    func testEmptyTitleBecomesNil() {
        XCTAssertNil(SurfaceContextComposer.sanitizedTitle("   ", applicationName: "Mail"))
        XCTAssertNil(SurfaceContextComposer.sanitizedTitle(nil, applicationName: "Mail"))
    }

    func testDomainExtractionDropsPathQueryAndWWW() {
        XCTAssertEqual(
            SurfaceContextComposer.registrableDomain(from: "https://www.mail.google.com/u/0/?compose=new"),
            "mail.google.com"
        )
        XCTAssertNil(SurfaceContextComposer.registrableDomain(from: nil))
        XCTAssertNil(SurfaceContextComposer.registrableDomain(from: "not a url"))
    }
}
