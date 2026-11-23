import Foundation
import XCTest

/// Hands each test a private `UserDefaults` suite and takes it away again when the test finishes.
///
/// Settings, metrics, and history types all persist through `UserDefaults`, so a test that used
/// `.standard` (or a fixed suite name) would read whatever an earlier test, a parallel test
/// process, or the developer's real app left behind. A UUID-named suite gives every caller a clean
/// slate without coordinating names.
///
/// Cleanup is done from a test observer instead of `addTeardownBlock` so that helpers which are not
/// `XCTestCase` methods (the coordinator rig factory) get the same guarantee. Call `make()` from
/// `setUp` or a test body: a suite created while no test is running is only removed after the next
/// test finishes.
enum IsolatedUserDefaults {
    static func make() -> UserDefaults {
        let suiteName = "CotabbyTests.isolated.\(UUID().uuidString)"
        // `UserDefaults(suiteName:)` is only nil for the main bundle identifier or the global
        // domain. Falling back to `.standard` here would let a test silently write into the
        // developer's real preferences, so a failure must stop the run instead.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create an isolated UserDefaults suite named \(suiteName)")
        }
        Cleanup.shared.track(suiteName)
        return defaults
    }

    /// Removes pending suites after every test case. Registered lazily on first use so suites that
    /// never touch defaults pay nothing.
    private final class Cleanup: NSObject, XCTestObservation {
        static let shared: Cleanup = {
            let cleanup = Cleanup()
            XCTestObservationCenter.shared.addTestObserver(cleanup)
            return cleanup
        }()

        private let lock = NSLock()
        /// Suites created by the test that is running now.
        private var pendingSuiteNames: [String] = []
        /// Suites whose domain was already emptied, kept for the end-of-run sweep.
        private var removedSuiteNames: [String] = []

        func track(_ suiteName: String) {
            lock.withLock { pendingSuiteNames.append(suiteName) }
        }

        func testCaseDidFinish(_ testCase: XCTestCase) {
            let suiteNames: [String] = lock.withLock {
                let names = pendingSuiteNames
                pendingSuiteNames.removeAll()
                removedSuiteNames.append(contentsOf: names)
                return names
            }
            for suiteName in suiteNames {
                UserDefaults.standard.removePersistentDomain(forName: suiteName)
                Self.deletePlist(for: suiteName)
            }
        }

        /// Removing a domain only empties it: cfprefsd still writes a zero-key plist to
        /// ~/Library/Preferences, on its own schedule, so that write can land after the per-test
        /// delete and recreate the file. By the end of the run those late writes have settled for
        /// all but the last few tests, so every suite's file is deleted once more here. Without
        /// this, thousands of empty plists pile up over repeated runs.
        func testBundleDidFinish(_ testBundle: Bundle) {
            let suiteNames = lock.withLock { removedSuiteNames }
            for suiteName in suiteNames {
                Self.deletePlist(for: suiteName)
            }
        }

        private static func deletePlist(for suiteName: String) {
            guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
                return
            }
            let plist = library
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(suiteName).plist")
            try? FileManager.default.removeItem(at: plist)
        }
    }
}
