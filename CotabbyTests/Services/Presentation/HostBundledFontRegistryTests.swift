import AppKit
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
}
