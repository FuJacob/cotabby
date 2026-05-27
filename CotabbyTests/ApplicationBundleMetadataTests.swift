import XCTest
@testable import Cotabby

/// Tests for the picker-to-rule resolution that backs "Add App" in Settings.
///
/// These exercise the pure initializer — the one that does not touch disk — so the display-name
/// fallback order and the bundle-identifier requirement are locked independently of whatever apps
/// happen to be installed on the machine running the suite.
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
}
