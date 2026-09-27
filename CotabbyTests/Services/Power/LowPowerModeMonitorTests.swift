import Combine
import XCTest
@testable import Cotabby

/// Tests for the Low Power Mode bridge's publishing contract. The coordinator reads the initial
/// value synchronously and treats every `lowPowerModeChanges` emission as a real transition, so the
/// stream must not replay `@Published`'s bootstrap value or repeat an unchanged one. The machine's
/// actual power state is not controllable here, so the tests only assert relative to it.
@MainActor
final class LowPowerModeMonitorTests: XCTestCase {
    /// `@MainActor` objects with observers are retained for the process lifetime to avoid the
    /// app-hosted isolated-deinit crash other suites work around the same way.
    private static var retainedMonitors: [LowPowerModeMonitor] = []

    private func makeMonitor() -> LowPowerModeMonitor {
        let monitor = LowPowerModeMonitor()
        Self.retainedMonitors.append(monitor)
        return monitor
    }

    func test_initialValueMirrorsProcessInfo() {
        XCTAssertEqual(makeMonitor().isLowPowerModeEnabled, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func test_changeStreamSkipsBootstrapAndUnchangedRefreshes() {
        let monitor = makeMonitor()
        var emissions: [Bool] = []
        let subscription = monitor.lowPowerModeChanges.sink { emissions.append($0) }
        defer { subscription.cancel() }

        // The power state has not changed, so neither subscribing nor refreshing is a transition.
        monitor.refreshLowPowerModeState()
        monitor.refreshLowPowerModeState()

        XCTAssertEqual(emissions, [])
    }
}
