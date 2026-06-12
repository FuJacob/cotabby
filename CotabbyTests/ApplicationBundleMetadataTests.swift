import XCTest
@testable import Cotabby

/// Tests for the picker-to-rule resolution that backs "Add App" in Settings.
///
/// The pure initializer locks the display-name fallback order and the bundle-identifier
/// requirement independently of whatever apps happen to be installed on the machine running the
/// suite. The disk-reading initializer is then exercised against minimal `.app` directories built
/// in a temp folder, so its plist extraction is covered without machine-specific fixtures.
final class ApplicationBundleMetadataTests: XCTestCase {
    func test_init_returnsNilWhenBundleIdentifierIsMissing() {
        XCTAssertNil(
            ApplicationBundleMetadata(
                bundleIdentifier: nil,
                infoDisplayName: "Raycast",
                infoBundleName: "Raycast",
                fileName: "Raycast"
            )
        )
    }

    func test_init_returnsNilWhenBundleIdentifierIsBlank() {
        XCTAssertNil(
            ApplicationBundleMetadata(
                bundleIdentifier: "   ",
                infoDisplayName: "Raycast",
                infoBundleName: nil,
                fileName: "Raycast"
            )
        )
    }

    func test_init_prefersDisplayNameOverBundleNameAndFileName() {
        let metadata = ApplicationBundleMetadata(
            bundleIdentifier: "com.raycast.macos",
            infoDisplayName: "Raycast",
            infoBundleName: "RaycastBundle",
            fileName: "Raycast 1.2.3"
        )

        XCTAssertEqual(metadata?.bundleIdentifier, "com.raycast.macos")
        XCTAssertEqual(metadata?.displayName, "Raycast")
    }

    func test_init_fallsBackToBundleNameWhenDisplayNameIsMissing() {
        let metadata = ApplicationBundleMetadata(
            bundleIdentifier: "com.microsoft.VSCode",
            infoDisplayName: nil,
            infoBundleName: "Code",
            fileName: "Visual Studio Code"
        )

        XCTAssertEqual(metadata?.displayName, "Code")
    }

    func test_init_fallsBackToFileNameWhenInfoNamesAreEmpty() {
        let metadata = ApplicationBundleMetadata(
            bundleIdentifier: "com.example.app",
            infoDisplayName: "  ",
            infoBundleName: nil,
            fileName: "Example"
        )

        XCTAssertEqual(metadata?.displayName, "Example")
    }

    func test_init_fallsBackToBundleIdentifierWhenEveryNameIsEmpty() {
        let metadata = ApplicationBundleMetadata(
            bundleIdentifier: "com.example.app",
            infoDisplayName: nil,
            infoBundleName: "",
            fileName: "   "
        )

        XCTAssertEqual(metadata?.displayName, "com.example.app")
    }

    func test_init_trimsResolvedBundleIdentifierAndDisplayName() {
        let metadata = ApplicationBundleMetadata(
            bundleIdentifier: "  com.example.app  ",
            infoDisplayName: "  Example App  ",
            infoBundleName: nil,
            fileName: "Example"
        )

        XCTAssertEqual(metadata?.bundleIdentifier, "com.example.app")
        XCTAssertEqual(metadata?.displayName, "Example App")
    }

    // MARK: - init(appURL:) against a real on-disk bundle

    // These build a minimal `.app` directory (Contents/Info.plist) in a temp folder so the
    // disk-reading initializer is exercised without depending on whatever apps the machine has.

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func test_initAppURL_readsIdentifierAndDisplayNameFromInfoPlist() throws {
        let appURL = try makeAppBundle(
            named: "Probe.app",
            info: [
                "CFBundleIdentifier": "com.example.probe",
                "CFBundleDisplayName": "Probe Display",
                "CFBundleName": "ProbeName"
            ]
        )

        let metadata = ApplicationBundleMetadata(appURL: appURL)

        XCTAssertEqual(metadata?.bundleIdentifier, "com.example.probe")
        XCTAssertEqual(metadata?.displayName, "Probe Display")
    }

    func test_initAppURL_fallsBackToBundleNameThenFileName() throws {
        let bundleNameOnly = try makeAppBundle(
            named: "NameOnly.app",
            info: ["CFBundleIdentifier": "com.example.nameonly", "CFBundleName": "Name Only"]
        )
        XCTAssertEqual(ApplicationBundleMetadata(appURL: bundleNameOnly)?.displayName, "Name Only")

        let identifierOnly = try makeAppBundle(
            named: "My Tool.app",
            info: ["CFBundleIdentifier": "com.example.mytool"]
        )
        // No Info.plist names at all: the file name minus `.app` is the closest thing to what the
        // user clicked in the open panel.
        XCTAssertEqual(ApplicationBundleMetadata(appURL: identifierOnly)?.displayName, "My Tool")
    }

    func test_initAppURL_returnsNilWhenBundleHasNoIdentifier() throws {
        let appURL = try makeAppBundle(
            named: "NoIdentifier.app",
            info: ["CFBundleDisplayName": "No Identifier"]
        )

        XCTAssertNil(
            ApplicationBundleMetadata(appURL: appURL),
            "A rule without a bundle identifier can never match a focused app"
        )
    }

    func test_initAppURL_returnsNilWhenURLDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-missing-\(UUID().uuidString).app", isDirectory: true)

        XCTAssertNil(ApplicationBundleMetadata(appURL: missing))
    }

    private func makeAppBundle(named name: String, info: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-bundle-test-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(root)
        let appURL = root.appendingPathComponent(name, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        return appURL
    }
}
