import Foundation
import XCTest
@testable import Cotabby

/// Locks `Bundle.cotabbyDisplayVersion`, the short "vX.Y" label shared by the sidebar header and
/// the Home hero. Each case builds a throwaway `.app` bundle with a hand-written Info.plist so the
/// result does not depend on the host app's real version.
///
/// `@MainActor` because the extension lives in the app target, whose default actor isolation is
/// the main actor.
@MainActor
final class BundleVersionTests: XCTestCase {
    func test_displayVersion_prefixesTheShortMarketingVersion() throws {
        try withBundle(info: ["CFBundleShortVersionString": "1.4.2", "CFBundleVersion": "812"]) { bundle in
            XCTAssertEqual(bundle.cotabbyDisplayVersion, "v1.4.2")
        }
    }

    func test_displayVersion_isNilWithoutAUsableShortVersion() throws {
        // The build number is deliberately not a fallback: the label is a marketing version only.
        let cases: [(name: String, info: [String: Any])] = [
            ("missing", ["CFBundleVersion": "812"]),
            ("empty", ["CFBundleShortVersionString": ""]),
            ("non-string", ["CFBundleShortVersionString": 3])
        ]
        for testCase in cases {
            try withBundle(info: testCase.info) { bundle in
                XCTAssertNil(bundle.cotabbyDisplayVersion, testCase.name)
            }
        }
    }

    /// Writes a minimal `Probe.app/Contents/Info.plist` under a unique temp directory, hands the
    /// loaded bundle to `body`, and removes the directory afterwards. A fresh path per call matters
    /// because `Bundle(url:)` caches instances by path.
    private func withBundle(info: [String: Any], perform body: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cotabby-bundle-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contentsURL = root
            .appendingPathComponent("Probe.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Probe.app", isDirectory: true)))
        try body(bundle)
    }
}
