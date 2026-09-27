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

    func testBasePrefaceKeepsDocumentFactsAndSubjectFieldWithoutSoftwareBranding() {
        let surface = SurfaceContext(surfaceClass: .email, applicationName: "Mail",
            windowTitle: "Budget review", domain: nil, fieldPlaceholder: "Subject")
        XCTAssertEqual(SurfaceContextComposer.baseCompletionPrefaceLines(for: surface),
                       ["Format: email; Title: Budget review; Field: Subject."])
        let generic = SurfaceContext(surfaceClass: .other, applicationName: "ChatGPT",
            windowTitle: "ChatGPT", domain: nil, fieldPlaceholder: "Message")
        XCTAssertEqual(SurfaceContextComposer.baseCompletionPrefaceLines(for: generic), ["Format: text."])
        XCTAssertEqual(
            SurfaceContextComposer.prefaceLines(for: generic),
            ["Format: text; App: ChatGPT; Title: ChatGPT; Field: Message."]
        )
    }

    /// The compact variant drops a title that merely repeats the app name and generic composer
    /// placeholders (matched case-insensitively), keeps a browser domain, and renders nothing for
    /// excluded classes.
    func testBasePrefaceOmitsRedundantFactsAndKeepsBrowserDomain() {
        let chat = SurfaceContext(surfaceClass: .chat, applicationName: "Slack",
            windowTitle: "slack", domain: nil, fieldPlaceholder: "Type a Message")
        XCTAssertEqual(SurfaceContextComposer.baseCompletionPrefaceLines(for: chat), ["Format: chat."])
        let browser = SurfaceContext(surfaceClass: .browser, applicationName: "Safari",
            windowTitle: "Docs", domain: "docs.example.com", fieldPlaceholder: "Add a comment")
        XCTAssertEqual(
            SurfaceContextComposer.baseCompletionPrefaceLines(for: browser),
            ["Format: web text; Domain: docs.example.com; Title: Docs; Field: Add a comment."]
        )
        for surfaceClass in [AppSurfaceClass.codeEditor, .terminal] {
            let excluded = SurfaceContext(surfaceClass: surfaceClass, applicationName: "Editor",
                windowTitle: "Project", domain: nil, fieldPlaceholder: nil)
            XCTAssertEqual(SurfaceContextComposer.baseCompletionPrefaceLines(for: excluded), [])
        }
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

    /// An app name that collapses to nothing leaves no trustworthy surface to describe.
    func testBlankApplicationNameIsOmitted() {
        XCTAssertNil(compose(applicationName: "  \n ", windowTitle: "Re: Q3"))
    }

    /// Any one fact is enough to describe a generic app. A domain alone still yields a surface,
    /// though only browsers render it.
    func testGenericAppWithOnlyPlaceholderOrDomainIsIncluded() throws {
        let placeholderOnly = try XCTUnwrap(compose(
            applicationName: "Bear", bundleIdentifier: "net.shinyfrog.bear", fieldPlaceholder: "Write here"
        ))
        XCTAssertEqual(SurfaceContextComposer.prefaceLines(for: placeholderOnly), ["Format: text; App: Bear; Field: Write here."])

        let domainOnly = try XCTUnwrap(compose(
            applicationName: "Bear", bundleIdentifier: "net.shinyfrog.bear", focusedURLString: "https://bear.app/notes"
        ))
        XCTAssertEqual(domainOnly.domain, "bear.app")
        XCTAssertEqual(SurfaceContextComposer.prefaceLines(for: domainOnly), ["Format: text; App: Bear."])
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
        // any app. The base preface keeps its browser-only domain scope.
        let cases: [(surfaceClass: AppSurfaceClass, format: String)] = [(.email, "email"), (.chat, "chat"), (.other, "text")]
        for testCase in cases {
            let surface = SurfaceContext(
                surfaceClass: testCase.surfaceClass, applicationName: "SomeApp", windowTitle: "Draft",
                domain: "private.example.com", fieldPlaceholder: "Message"
            )
            XCTAssertEqual(
                SurfaceContextComposer.prefaceLines(for: surface),
                ["Format: \(testCase.format); App: SomeApp; Title: Draft; Field: Message."],
                "\(testCase.surfaceClass)"
            )
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

    /// The trailing app-name suffix is removed once, case-insensitively, for hyphen, em dash, and
    /// en dash separators; an app name elsewhere in the title is left alone.
    func testTitleAppNameSuffixIsStripped() {
        let cases: [(title: String, app: String, expected: String)] = [
            ("Inbox (3) - Google Chrome", "Google Chrome", "Inbox (3)"),
            ("Notes — Pages", "Pages", "Notes"),
            ("Draft – Pages", "Pages", "Draft"),
            ("Inbox - google chrome", "Google Chrome", "Inbox"),
            ("Pages - Notes - Pages", "Pages", "Pages - Notes"),
            ("Pages - Notes", "Pages", "Pages - Notes")
        ]
        for testCase in cases {
            XCTAssertEqual(
                SurfaceContextComposer.sanitizedTitle(testCase.title, applicationName: testCase.app),
                testCase.expected,
                testCase.title
            )
        }
    }

    func testTitleIsCappedAndWhitespaceCollapsed() {
        let long = String(repeating: "title ", count: 40)
        XCTAssertEqual(
            SurfaceContextComposer.sanitizedTitle(long, applicationName: "Mail"),
            String(repeating: "title ", count: 13) + "ti"
        )

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
        XCTAssertEqual(SurfaceContextComposer.registrableDomain(from: "https://Docs.Example.COM/x"), "docs.example.com")
        for input in [nil, "", "not a url", "mailto:jane@example.com"] as [String?] {
            XCTAssertNil(SurfaceContextComposer.registrableDomain(from: input), "input \(input ?? "nil")")
        }
    }

    /// Placeholders get the same quote/control/whitespace cleanup as titles and a 60-character cap.
    func testPlaceholderIsSanitizedAndCapped() throws {
        let cleaned = try XCTUnwrap(compose(fieldPlaceholder: "  Write \"your\"\u{07}   reply  "))
        XCTAssertEqual(cleaned.fieldPlaceholder, "Write your reply")

        let long = try XCTUnwrap(compose(fieldPlaceholder: String(repeating: "p", count: 70)))
        XCTAssertEqual(long.fieldPlaceholder, String(repeating: "p", count: 60))
    }
}
