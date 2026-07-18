import XCTest
@testable import Cotabby

/// Drives `FocusTrackingModel` through its observable lifecycle with a permission provider that
/// always answers `false`. That keeps every capture on the deterministic "permission missing"
/// path: no Accessibility reads, no dependence on whatever window happens to be focused on the
/// machine running the tests, while still exercising the model's publishing and polling plumbing.
///
/// `FocusTrackingModel` is `@MainActor` with stored properties and no `nonisolated deinit`, so
/// instances are quarantined in a process-lifetime retain list (the `InputMonitorTests` pattern)
/// and every interaction runs through `runOnMainActor`.
final class FocusTrackingModelTests: XCTestCase {
    @MainActor private static var retainedModels: [FocusTrackingModel] = []

    /// The exact snapshot the tracker publishes when Accessibility permission is missing.
    /// Asserted verbatim because the menu bar UI renders these strings.
    private static let blockedApplicationName = "Accessibility permission missing"

    @MainActor
    private func makeModel(publishesPollingEvents: Bool = false) -> FocusTrackingModel {
        let model = FocusTrackingModel(
            permissionProvider: { false },
            ignoredBundleIdentifier: nil,
            publishesPollingEvents: publishesPollingEvents
        )
        Self.retainedModels.append(model)
        // The retain list keeps instances alive for the whole run, so make sure no poll timer
        // outlives its test even when an assertion fails first.
        addTeardownBlock {
            runOnMainActor { model.stop() }
        }
        return model
    }

    func test_init_startsInactiveWithoutEventsOrExternalApp() {
        runOnMainActor {
            let model = makeModel()

            XCTAssertEqual(model.snapshot, .inactive)
            XCTAssertNil(model.latestExternalApplication)
            XCTAssertNil(model.latestPollEvent)
        }
    }

    func test_start_publishesPermissionBlockedSnapshot() {
        runOnMainActor {
            let model = makeModel()

            model.start()

            XCTAssertEqual(model.snapshot.applicationName, Self.blockedApplicationName)
            XCTAssertEqual(model.snapshot.capability, .blocked("Accessibility permission is required."))
            XCTAssertNil(model.snapshot.bundleIdentifier)
            // A nil bundle identifier can never become the "Enable in X" target.
            XCTAssertNil(model.latestExternalApplication)
        }
    }

    func test_start_emitsPollingEventsWhenEnabled() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: true)

            model.start()

            let event = model.latestPollEvent
            XCTAssertEqual(event?.sequence, 1, "start() must capture immediately, not wait for a tick")
            XCTAssertEqual(event?.applicationName, Self.blockedApplicationName)
            XCTAssertEqual(event?.capabilitySummary, "Blocked")
            XCTAssertEqual(event?.didChangeFocusedInput, false)
        }
    }

    func test_start_whileStarted_actsAsImmediateRefresh() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: true)
            model.start()
            let snapshotAfterFirstStart = model.snapshot

            model.start()

            XCTAssertEqual(model.latestPollEvent?.sequence, 2, "Second start() should re-poll, not re-arm")
            XCTAssertEqual(model.snapshot, snapshotAfterFirstStart, "A stable capture must not churn the snapshot")
        }
    }

    func test_start_withoutPollingPublication_keepsLatestPollEventNil() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: false)

            model.start()

            XCTAssertEqual(model.snapshot.applicationName, Self.blockedApplicationName)
            XCTAssertNil(model.latestPollEvent, "Debug polling events are opt-in")
        }
    }

    func test_refreshNow_capturesOnDemand() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: true)
            model.start()

            model.refreshNow()

            XCTAssertEqual(model.latestPollEvent?.sequence, 2)
        }
    }

    func test_stop_leavesLastSnapshotAvailableAndAllowsManualRefresh() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: true)
            model.start()

            model.stop()

            XCTAssertEqual(model.snapshot.applicationName, Self.blockedApplicationName)

            // Manual refreshes still work while observation is stopped; only the timer is gone.
            model.refreshNow()
            XCTAssertEqual(model.latestPollEvent?.sequence, 2)
        }
    }

    func test_updatePollInterval_isNoOpForUnchangedInterval() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: true)
            model.start()

            // 80 ms is the tracker's default cadence: re-applying it must not restart polling.
            model.updatePollInterval(milliseconds: 80)

            XCTAssertEqual(model.latestPollEvent?.sequence, 1)
        }
    }

    func test_updatePollInterval_restartsActivePollingOnChange() {
        runOnMainActor {
            let model = makeModel(publishesPollingEvents: true)
            model.start()

            model.updatePollInterval(milliseconds: 133)

            // The restart performs an immediate capture, which is observable as a new poll event.
            XCTAssertEqual(model.latestPollEvent?.sequence, 2)
        }
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
