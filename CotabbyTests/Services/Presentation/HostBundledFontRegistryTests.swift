import AppKit
import Security
import XCTest
@testable import Cotabby

/// The registry scans a host bundle's resources for the text faces its editor may be set in. A
/// throwaway directory laid out like a bundle stands in for the host; the fonts are copies of
/// system files, whose registration reports them already available and whose names are known.
final class HostBundledFontRegistryTests: XCTestCase {
    private var resources: URL!

    override func setUpWithError() throws {
        resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-host-fonts-\(UUID().uuidString)/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("fonts/deep/er", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Anything the registry registered from the copies must be unregistered before the copies
        // are deleted, or CoreText keeps a face that points at a missing file.
        for file in HostBundledFontRegistry.fontFiles(under: resources) {
            CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
        }
        try? FileManager.default.removeItem(at: resources.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func copySystemFont(_ name: String, to relativePath: String) throws {
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/\(name)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "\(name) is not installed here")
        try FileManager.default.copyItem(at: source, to: resources.appendingPathComponent(relativePath))
    }

    func testRegularUprightTextFacesAreListedAndBoldItalicOnesAreNot() throws {
        try copySystemFont("Arial.ttf", to: "fonts/Arial.ttf")
        try copySystemFont("Arial Bold.ttf", to: "fonts/Arial Bold.ttf")
        try copySystemFont("Arial Italic.ttf", to: "fonts/Arial Italic.ttf")
        try copySystemFont("Georgia.ttf", to: "fonts/deep/er/Georgia.ttf")

        let names = HostBundledFontRegistry.registerTextFaces(under: resources)

        XCTAssertTrue(names.contains("ArialMT"), "\(names)")
        XCTAssertTrue(names.contains("Georgia"), "a nested fonts folder is still the host's: \(names)")
        XCTAssertFalse(names.contains("Arial-BoldMT"), "\(names)")
        XCTAssertFalse(names.contains("Arial-ItalicMT"), "\(names)")
        for name in names {
            XCTAssertNotNil(NSFont(name: name, size: 15.4), "every listed face must resolve at any size")
        }
        // These faces are installed here, so the copies were never registered: the installed
        // Georgia still renders after the copies are gone.
        XCTAssertTrue(HostBundledFontRegistry.fontFiles(under: resources).allSatisfy {
            CTFontManagerUnregisterFontsForURL($0 as CFURL, .process, nil) == false
        }, "nothing to unregister")
    }

    func testFilesBeyondTheDepthLimitAndNonFontsAreIgnored() throws {
        let tooDeep = resources.appendingPathComponent("a/b/c/d/e", isDirectory: true)
        try FileManager.default.createDirectory(at: tooDeep, withIntermediateDirectories: true)
        try copySystemFont("Arial.ttf", to: "a/b/c/d/e/Arial.ttf")
        try Data("not a font".utf8).write(to: resources.appendingPathComponent("fonts/readme.txt"))
        try Data([0, 1, 2]).write(to: resources.appendingPathComponent("fonts/broken.ttf"))

        XCTAssertTrue(HostBundledFontRegistry.fontFiles(under: resources).allSatisfy { $0.lastPathComponent == "broken.ttf" })
        XCTAssertEqual(HostBundledFontRegistry.registerTextFaces(under: resources), [], "a broken file yields no face")
    }

    func testAFontWithoutLettersIsNotATextFace() throws {
        // The emoji font is upright and regular but sets no letters; an icon webfont bundled by an
        // Electron app looks the same to CoreText and must be rejected on that alone.
        let emoji = URL(fileURLWithPath: "/System/Library/Fonts/Apple Color Emoji.ttc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: emoji.path))
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(emoji as CFURL) as? [CTFontDescriptor] ?? []
        try XCTSkipUnless(!descriptors.isEmpty)
        XCTAssertFalse(descriptors.contains { HostBundledFontRegistry.isUprightRegularTextFace($0) })
        let arial = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        let arialDescriptors = CTFontManagerCreateFontDescriptorsFromURL(arial as CFURL) as? [CTFontDescriptor] ?? []
        XCTAssertTrue(arialDescriptors.contains { HostBundledFontRegistry.isUprightRegularTextFace($0) })
    }

    @MainActor
    func testAnUnknownBundleYieldsNothingWithoutScanning() {
        let registry = HostBundledFontRegistry()
        XCTAssertEqual(registry.candidateFontNames(forBundleIdentifier: "com.example.not-running"), [])
        XCTAssertEqual(registry.candidateFontNames(forBundleIdentifier: nil), [])
    }

    // MARK: - Host trust

    /// A focused app controls both its bundle id and the files in its bundle, so only named hosts
    /// may ever hand fonts to CoreText here, matched exactly like the requirement's identifier.
    func testOnlyAllowlistedHostsAreTrusted() {
        XCTAssertTrue(HostBundledFontRegistry.isTrustedHost(bundleIdentifier: "com.anthropic.claudefordesktop"))
        for bundleIdentifier in [
            "com.microsoft.VSCode", "md.obsidian", "com.google.Chrome",
            "com.anthropic.claudefordesktop.evil", "COM.ANTHROPIC.CLAUDEFORDESKTOP", ""
        ] {
            XCTAssertFalse(HostBundledFontRegistry.isTrustedHost(bundleIdentifier: bundleIdentifier), bundleIdentifier)
        }
    }

    func testEveryAllowlistedHostHasACompilableRequirementPinningItsIdentifierAndPublisher() {
        XCTAssertFalse(HostBundledFontRegistry.trustedHostTeamIdentifiers.isEmpty)
        for (bundleIdentifier, teamIdentifier) in HostBundledFontRegistry.trustedHostTeamIdentifiers {
            let text = HostFontRegistry.codeRequirement(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, bundleIdentifier)
            XCTAssertTrue(text.hasPrefix("identifier \"\(bundleIdentifier)\" and "), text)
            XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"\(teamIdentifier)\""), text)
        }
    }

    /// An allowlisted name is not enough: this test host is not signed by the host's publisher.
    func testABundleNotSignedByTheHostsPublisherFailsTheTrustCheck() {
        XCTAssertFalse(
            HostBundledFontRegistry.bundleIsTrusted(at: Bundle.main.bundleURL, bundleIdentifier: "com.anthropic.claudefordesktop")
        )
        XCTAssertFalse(
            HostBundledFontRegistry.bundleIsTrusted(at: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        )
    }

    func testInstalledClaudeDesktopPassesTheTrustCheck() throws {
        let claude = URL(fileURLWithPath: "/Applications/Claude.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: claude.path), "Claude desktop is not installed")

        XCTAssertTrue(HostBundledFontRegistry.bundleIsTrusted(at: claude, bundleIdentifier: "com.anthropic.claudefordesktop"))
    }

    /// The identifier pin: a genuine app from another publisher cannot stand in for the host.
    func testAGenuineAppFromAnotherPublisherCannotStandInForTheHost() throws {
        let other = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: other.path), "TextEdit is not installed")

        XCTAssertFalse(HostBundledFontRegistry.bundleIsTrusted(at: other, bundleIdentifier: "com.anthropic.claudefordesktop"))
    }
}
