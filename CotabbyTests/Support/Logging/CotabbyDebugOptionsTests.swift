import Foundation
import XCTest
@testable import Cotabby

/// Locks the logging verbosity floor: the documented `COTABBY_LOG_LEVEL` precedence over the
/// `-cotabby-debug` default, the swift-log-to-OSLog bridge that applies it, and the once-only
/// logging bootstrap.
///
/// Environment-variable tests mutate the process environment through `setenv`/`unsetenv` and
/// restore the prior value before returning; XCTest runs the methods in this bundle serially, so
/// no other test can observe the temporary value.
final class CotabbyDebugOptionsTests: XCTestCase {
    private static let levelKey = "COTABBY_LOG_LEVEL"

    /// Runs `body` with the environment variable forced to `value` (or removed when nil), then
    /// restores whatever was there before, even if `body` throws or skips.
    private func withEnvironmentValue(
        _ key: String,
        _ value: String?,
        perform body: () throws -> Void
    ) rethrows {
        let previous = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        try body()
    }

    // MARK: - Verbosity floor precedence

    func test_minimumLogLevel_honorsEveryRecognizedOverrideCaseInsensitively() {
        let cases: [(raw: String, expected: String)] = [
            ("trace", "trace"),
            ("debug", "debug"),
            ("info", "info"),
            ("notice", "notice"),
            ("warning", "warning"),
            ("error", "error"),
            ("critical", "critical"),
            ("WARNING", "warning"),
            ("Debug", "debug")
        ]
        for testCase in cases {
            withEnvironmentValue(Self.levelKey, testCase.raw) {
                XCTAssertEqual(
                    CotabbyDebugOptions.minimumLogLevel.rawValue,
                    testCase.expected,
                    "COTABBY_LOG_LEVEL=\(testCase.raw)"
                )
            }
        }
    }

    func test_minimumLogLevel_ignoresUnrecognizedOverride() {
        // A bogus override must fall back to the launch-argument default, not crash or stick.
        // Whitespace is not trimmed, so a padded value is also unrecognized.
        let fallback = CotabbyDebugOptions.isEnabled ? "trace" : "info"
        for raw in ["chatty", "", " warning", "warn"] {
            withEnvironmentValue(Self.levelKey, raw) {
                XCTAssertEqual(
                    CotabbyDebugOptions.minimumLogLevel.rawValue,
                    fallback,
                    "COTABBY_LOG_LEVEL=\"\(raw)\""
                )
            }
        }
    }

    func test_minimumLogLevel_defaultsToInfo() throws {
        try withEnvironmentValue(Self.levelKey, nil) {
            try XCTSkipIf(CotabbyDebugOptions.isEnabled, "Runner was launched with -cotabby-debug")
            XCTAssertEqual(CotabbyDebugOptions.minimumLogLevel.rawValue, "info")
        }
    }

    // MARK: - Logger plumbing

    func test_bootstrap_isIdempotent() {
        // The host app already bootstrapped logging at launch; repeated calls must be safe no-ops
        // (LoggingSystem traps on a second real bootstrap, so this locks the once-only guard).
        CotabbyLogger.bootstrap()
        CotabbyLogger.bootstrap()
    }

    // MARK: - OSLogHandler

    func test_osLogHandler_defaultFloorTracksGlobalConfiguration() {
        let handler = OSLogHandler(label: "com.cotabby.test-floor")

        XCTAssertEqual(handler.logLevel.rawValue, CotabbyDebugOptions.minimumLogLevel.rawValue)
    }
}
