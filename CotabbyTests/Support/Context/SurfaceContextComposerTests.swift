import XCTest
@testable import Cotabby

/// Locks in the two invariants of surface conditioning: omission beats noise (code editors,
/// terminals, and anonymous generic apps get no section at all), and everything user-derived
/// (titles, placeholders, URLs) is sanitized before it can reach a prompt. Compact labels must
/// preserve the available facts and stable field order without adding absent metadata.
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

    func testGenericAppWithTitleIsIncluded() throws {
        let surface = compose(
            applicationName: "Bear",
            bundleIdentifier: "net.shinyfrog.bear",
            windowTitle: "Travel plans"
        )
        XCTAssertEqual(surface?.surfaceClass, .other)
        XCTAssertEqual(surface?.windowTitle, "Travel plans")
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: try XCTUnwrap(surface)),
            ["Format: text; App: Bear; Title: Travel plans."]
        )
    }

    // MARK: - Preface lines

    func testEmailPreface() throws {
        let surface = compose(windowTitle: "Re: Q3 budget review")
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: try XCTUnwrap(surface)),
            ["Format: email; App: Mail; Title: Re: Q3 budget review."]
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
            ["Format: chat; App: Slack; Field: Message #design."]
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
            ["Format: web text; App: Google Chrome; Domain: notion.so."]
        )
    }

    func testCompactPrefacePreservesAllSanitizedBrowserFacts() throws {
        let surface = try XCTUnwrap(compose(
            applicationName: "  Google   Chrome  ",
            bundleIdentifier: "com.google.Chrome",
            windowTitle: "Planning \"notes\" - Google Chrome",
            focusedURLString: "https://www.docs.example.com/private-draft?token=secret#section",
            fieldPlaceholder: "  Add   a comment  "
        ))
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: surface),
            ["Format: web text; App: Google Chrome; Domain: docs.example.com; Title: Planning notes; Field: Add a comment."]
        )
    }

    func testBrowserWithoutOptionalFactsKeepsOnlyFormatAndApp() throws {
        let surface = try XCTUnwrap(compose(
            applicationName: "Safari", bundleIdentifier: "com.apple.Safari"
        ))
        XCTAssertEqual(SurfaceContextComposer.prefaceLines(for: surface), ["Format: web text; App: Safari."])
    }

    func testNonBrowserSurfacesKeepOriginalDomainOmission() {
        // SurfaceContext is shared with the Foundation Models renderer and may carry a host for
        // any app. Compact formatting must preserve the base preface's browser-only domain scope.
        for surfaceClass in [AppSurfaceClass.email, .chat, .other] {
            let surface = SurfaceContext(
                surfaceClass: surfaceClass, applicationName: "SomeApp", windowTitle: "Draft",
                domain: "private.example.com", fieldPlaceholder: "Message"
            )
            let preface = SurfaceContextComposer.prefaceLines(for: surface).joined(separator: " ")
            XCTAssertFalse(preface.contains("Domain:"))
            XCTAssertFalse(preface.contains("private.example.com"))
            XCTAssertTrue(preface.contains("App: SomeApp; Title: Draft; Field: Message."))
        }
    }

    func testExcludedSurfaceValuesCannotRenderMetadata() {
        // The value type is shared across renderers and can be constructed without compose().
        // Protect omission at this rendering boundary as well as at focus metadata composition.
        for surfaceClass in [AppSurfaceClass.codeEditor, .terminal] {
            let surface = SurfaceContext(
                surfaceClass: surfaceClass, applicationName: "Editor", windowTitle: "Project",
                domain: "example.com", fieldPlaceholder: "Command"
            )
            XCTAssertEqual(SurfaceContextComposer.prefaceLines(for: surface), [])
        }
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
