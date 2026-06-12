import Foundation
import XCTest
@testable import Cotabby

/// Locks the developer-diagnostics gate and the logging verbosity floor: the launch-argument
/// contract, the documented `COTABBY_LOG_LEVEL` precedence, and the swift-log-to-OSLog bridge.
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

    // MARK: - Debug gate

    func test_launchArgument_matchesDocumentedFlag() {
        XCTAssertEqual(CotabbyDebugOptions.launchArgument, "-cotabby-debug")
    }

    func test_isEnabled_mirrorsProcessLaunchArguments() {
        XCTAssertEqual(
            CotabbyDebugOptions.isEnabled,
            ProcessInfo.processInfo.arguments.contains(CotabbyDebugOptions.launchArgument),
            "The debug gate must key off the launch argument and nothing else"
        )
    }

    func test_log_staysQuietWhenDebugModeIsOff() throws {
        try XCTSkipIf(CotabbyDebugOptions.isEnabled, "Runner was launched with -cotabby-debug")

        // The guard is the privacy gate: without the explicit launch argument this must be a
        // no-op rather than writing diagnostics anywhere.
        CotabbyDebugOptions.log("coverage probe, should never be emitted")
    }

    // MARK: - Verbosity floor precedence

    func test_minimumLogLevel_honorsExplicitEnvironmentOverride() {
        withEnvironmentValue(Self.levelKey, "warning") {
            XCTAssertEqual(CotabbyDebugOptions.minimumLogLevel.rawValue, "warning")
        }
        withEnvironmentValue(Self.levelKey, "error") {
            XCTAssertEqual(CotabbyDebugOptions.minimumLogLevel.rawValue, "error")
        }
    }

    func test_minimumLogLevel_ignoresUnrecognizedOverride() {
        withEnvironmentValue(Self.levelKey, "chatty") {
            let expected = CotabbyDebugOptions.isEnabled ? "trace" : "info"
            XCTAssertEqual(
                CotabbyDebugOptions.minimumLogLevel.rawValue,
                expected,
                "A bogus override must fall back to the launch-argument default, not crash or stick"
            )
        }
    }

    func test_minimumLogLevel_normalizesOverrideCasing() {
        withEnvironmentValue(Self.levelKey, "WARNING") {
            XCTAssertEqual(CotabbyDebugOptions.minimumLogLevel.rawValue, "warning")
        }
    }

    func test_minimumLogLevel_defaultsToInfo() throws {
        try withEnvironmentValue(Self.levelKey, nil) {
            try XCTSkipIf(CotabbyDebugOptions.isEnabled, "Runner was launched with -cotabby-debug")
            XCTAssertEqual(CotabbyDebugOptions.minimumLogLevel.rawValue, "info")
        }
    }

    // MARK: - Logger plumbing

    func test_llmIOLabel_isTheReservedRoutingContract() {
        // FileLogHandler routing and the jq-based debugging workflow both key off this label.
        XCTAssertEqual(CotabbyLogger.llmIOLabel, "com.cotabby.llm-io")
    }

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

    func test_osLogHandler_acceptsExplicitFloor() {
        let handler = OSLogHandler(label: "com.cotabby.test-floor", logLevel: .critical)

        XCTAssertEqual(handler.logLevel.rawValue, "critical")
    }

    func test_osLogHandler_metadataSubscriptReadsAndWrites() {
        var handler = OSLogHandler(label: "com.cotabby.test-metadata")

        XCTAssertNil(handler[metadataKey: "request_id"])

        handler[metadataKey: "request_id"] = .string("req_test1234")
        XCTAssertEqual(handler[metadataKey: "request_id"], .string("req_test1234"))

        handler[metadataKey: "request_id"] = nil
        XCTAssertNil(handler[metadataKey: "request_id"])
    }

    func test_loggerCopy_canLowerItsOwnFloorWithoutLeakingGlobally() {
        // Logger is a value type: a call site may locally drop the floor to trace and emit at
        // every level (exercising the full OSLog bridge switch) without mutating the shared
        // logger's configuration.
        var logger = CotabbyLogger.debug
        logger.logLevel = .trace

        logger.trace("bridge probe: trace")
        logger.debug("bridge probe: debug")
        logger.info("bridge probe: info")
        logger.notice("bridge probe: notice")
        logger.warning("bridge probe: warning")
        logger.error("bridge probe: error")
        logger.critical("bridge probe: critical")

        XCTAssertEqual(logger.logLevel.rawValue, "trace")
        XCTAssertEqual(
            CotabbyLogger.debug.logLevel.rawValue,
            CotabbyDebugOptions.minimumLogLevel.rawValue,
            "Mutating a copied logger must not change the shared instance's floor"
        )
    }
}
