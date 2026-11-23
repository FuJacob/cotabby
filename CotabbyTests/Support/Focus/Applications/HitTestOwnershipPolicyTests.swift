import XCTest
@testable import Cotabby

/// The Chromium hit-test fallback attributes whatever it adopts to the frontmost app, so an element
/// from any other app must be rejected; otherwise the pointer resting over a neighbouring window
/// would read that app's field under the browser's per-app settings.
final class HitTestOwnershipPolicyTests: XCTestCase {
    private func accepts(
        elementPID: pid_t?,
        elementBundle: String?,
        frontmostPID: pid_t = 100,
        frontmostBundle: String? = "com.google.Chrome"
    ) -> Bool {
        HitTestOwnershipPolicy.belongsToFrontmostApplication(
            elementPID: elementPID,
            elementBundleIdentifier: elementBundle,
            frontmostPID: frontmostPID,
            frontmostBundleIdentifier: frontmostBundle
        )
    }

    func testElementServedByTheFrontmostProcessIsAdopted() {
        XCTAssertTrue(accepts(elementPID: 100, elementBundle: "com.google.Chrome"))
        XCTAssertTrue(accepts(elementPID: 100, elementBundle: nil, frontmostBundle: "md.obsidian"))
    }

    func testElementFromAnotherAppUnderThePointerIsRejected() {
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.apple.Terminal"))
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.microsoft.VSCode", frontmostBundle: "md.obsidian"))
        // A second Chromium browser beside the frontmost one is still a different app.
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.brave.Browser"))
        // So is a regular browser window beside a different browser's installed web app.
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.brave.Browser", frontmostBundle: "com.google.Chrome.app.abc"))
    }

    func testChromiumAppShimAcceptsContentServedByItsHostBrowser() {
        XCTAssertTrue(accepts(elementPID: 200, elementBundle: "com.google.Chrome", frontmostBundle: "com.google.Chrome.app.Default-abc"))
        XCTAssertTrue(accepts(elementPID: 200, elementBundle: "com.microsoft.edgemac", frontmostBundle: "com.microsoft.edgemac.app.xyz"))
    }

    func testShimAllowanceIsLimitedToChromiumHostsAndTheAppSeparator() {
        // A non-Chromium owner never qualifies, even when the frontmost id happens to extend it.
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.example", frontmostBundle: "com.example.app.chrome"))
        // A browser channel is a separate app, not a shim of the stable build.
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.google.Chrome", frontmostBundle: "com.google.Chrome.canary"))
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.google.Chrome", frontmostBundle: "com.google.Chrome.application"))
    }

    func testUnknownOwnershipFailsClosed() {
        XCTAssertFalse(accepts(elementPID: nil, elementBundle: "com.google.Chrome"))
        XCTAssertFalse(accepts(elementPID: 0, elementBundle: "com.google.Chrome", frontmostPID: 0))
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: nil))
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "", frontmostBundle: ".app.x"))
        XCTAssertFalse(accepts(elementPID: 200, elementBundle: "com.google.Chrome", frontmostBundle: nil))
    }
}
