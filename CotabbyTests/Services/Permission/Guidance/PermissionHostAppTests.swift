import AppKit
import XCTest
@testable import Cotabby

/// Tests for the app identity shown in the drag-to-grant permission overlay. Each case builds a
/// throwaway `.app` directory with a hand-written Info.plist so the name fallback chain is pinned
/// without depending on how the test host itself is bundled.
@MainActor
final class PermissionHostAppTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionHostAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
        try super.tearDownWithError()
    }

    /// Creates `<name>.app/Contents/Info.plist` with `info` and returns the bundle.
    private func makeBundle(named name: String, info: [String: String]) throws -> Bundle {
        let bundleURL = temporaryRoot.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    func test_displayNameWinsOverBundleName() throws {
        let bundle = try makeBundle(named: "Fixture", info: [
            "CFBundleIdentifier": "com.example.fixture.display",
            "CFBundleDisplayName": "Friendly Fixture",
            "CFBundleName": "FixtureInternal"
        ])

        XCTAssertEqual(PermissionHostApp.current(bundle: bundle).displayName, "Friendly Fixture")
    }

    func test_bundleNameIsUsedWithoutADisplayName() throws {
        let bundle = try makeBundle(named: "Fixture", info: [
            "CFBundleIdentifier": "com.example.fixture.name",
            "CFBundleName": "FixtureInternal"
        ])

        XCTAssertEqual(PermissionHostApp.current(bundle: bundle).displayName, "FixtureInternal")
    }

    func test_bundleFolderNameIsTheLastResort() throws {
        let bundle = try makeBundle(named: "Nameless Fixture", info: [
            "CFBundleIdentifier": "com.example.fixture.nameless"
        ])

        // The `.app` extension is stripped so the overlay reads like Finder does.
        XCTAssertEqual(PermissionHostApp.current(bundle: bundle).displayName, "Nameless Fixture")
    }

    func test_carriesTheBundleURLAndAnOverlaySizedIcon() throws {
        let bundle = try makeBundle(named: "Fixture", info: ["CFBundleName": "Fixture"])

        let host = PermissionHostApp.current(bundle: bundle)

        // The URL is the drag payload System Settings receives, so it must be the bundle itself.
        XCTAssertEqual(host.bundleURL, bundle.bundleURL)
        XCTAssertEqual(host.icon.size, NSSize(width: 48, height: 48))
    }
}
