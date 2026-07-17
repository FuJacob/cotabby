import XCTest
@testable import Cotabby

/// Tests for the app identity that menu-bar controls target.
///
/// This is deliberately a pure model test instead of a SwiftUI test. The behavior we care about is
/// not pixels; it is the invariant that Cotabby's own transient focus does not become the app rule
/// target after the user opens the menu bar.
final class FocusSnapshotExternalApplicationIdentityTests: XCTestCase {
    func test_externalApplicationIdentity_returnsNonCotabbyApplication() {
        let snapshot = FocusSnapshot(
            applicationName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            capability: .supported,
            context: nil
        )

        XCTAssertEqual(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby"),
            FocusedApplicationIdentity(
                applicationName: "Google Chrome",
                bundleIdentifier: "com.google.Chrome"
            )
        )
    }

    func test_externalApplicationIdentity_ignoresCotabbyApplication() {
        let snapshot = FocusSnapshot(
            applicationName: "Cotabby",
            bundleIdentifier: "com.jacobfu.tabby",
            capability: .blocked("Cotabby is focused."),
            context: nil
        )

        XCTAssertNil(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby")
        )
    }

    func test_externalApplicationIdentity_returnsNilWhenBundleIdentifierIsMissing() {
        let snapshot = FocusSnapshot(
            applicationName: "Unknown",
            bundleIdentifier: nil,
            capability: .unsupported("No active application."),
            context: nil
        )

        XCTAssertNil(
            snapshot.externalApplicationIdentity(ignoredBundleIdentifier: "com.jacobfu.tabby")
        )
    }
}
