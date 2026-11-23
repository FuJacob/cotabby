import XCTest
@testable import Cotabby

/// Transition tests for the accept tap's lifecycle. Each rule here protects keystrokes: the tap
/// must be off the synchronous path when nothing needs it, and must never be switched off or
/// released while input is still in flight or a newer reason has re-armed it.
final class AcceptTapLifecycleTests: XCTestCase {
    private typealias Effect = AcceptTapLifecycle.Effect

    private func interceptingForSuggestion() -> AcceptTapLifecycle {
        var lifecycle = AcceptTapLifecycle()
        _ = lifecycle.setReason(.suggestion, active: true, hasPermission: true)
        return lifecycle
    }

    /// Drives an intercepting lifecycle through the quiet period into `parked`, returning the
    /// generation its release timer was scheduled with.
    private func park(_ lifecycle: inout AcceptTapLifecycle) -> UInt64 {
        guard case .scheduleIdleCheck(let generation, _) =
            lifecycle.setReason(.suggestion, active: false, hasPermission: true) else {
            XCTFail("Dropping the last reason must schedule an idle check")
            return 0
        }
        _ = lifecycle.idleCheckFired(generation: generation, hasPermission: true, lastKeyDownUptime: nil, nowUptime: 100)
        return generation
    }

    // MARK: - Arming

    func test_firstReasonInstallsTheTap() {
        var lifecycle = AcceptTapLifecycle()

        XCTAssertEqual(
            lifecycle.setReason(.suggestion, active: true, hasPermission: true),
            .intercept(reenableParkedTap: false)
        )
        XCTAssertEqual(lifecycle.phase, .intercepting)
        XCTAssertTrue(lifecycle.isTapEnabled)
    }

    func test_reasonWithoutPermissionIsRememberedButDoesNotArmTheTap() {
        var lifecycle = AcceptTapLifecycle()

        XCTAssertEqual(lifecycle.setReason(.suggestion, active: true, hasPermission: false), Effect.none)
        XCTAssertEqual(lifecycle.phase, .absent)
        XCTAssertEqual(lifecycle.reasons, [.suggestion])
        XCTAssertFalse(lifecycle.ownsAcceptKeys)
    }

    func test_everyWantedChangeAsksForATapSoAFailedInstallIsRetried() {
        var lifecycle = interceptingForSuggestion()

        XCTAssertEqual(
            lifecycle.setReason(.emojiCapture, active: true, hasPermission: true),
            .intercept(reenableParkedTap: false)
        )
    }

    // MARK: - Accept-key ownership

    func test_onlyAVisibleSuggestionOwnsTheAcceptKey() {
        var lifecycle = AcceptTapLifecycle()
        _ = lifecycle.setReason(.emojiCapture, active: true, hasPermission: true)
        XCTAssertFalse(lifecycle.ownsAcceptKeys, "A tap installed only for emoji capture must not claim the accept key")

        _ = lifecycle.setReason(.suggestion, active: true, hasPermission: true)
        XCTAssertTrue(lifecycle.ownsAcceptKeys)

        _ = lifecycle.setReason(.suggestion, active: false, hasPermission: true)
        XCTAssertFalse(lifecycle.ownsAcceptKeys)
        XCTAssertEqual(lifecycle.phase, .intercepting, "Emoji capture still needs the tap")
    }

    func test_ownershipEndsTheMomentTheTapIsNoLongerWanted() {
        var lifecycle = interceptingForSuggestion()

        _ = lifecycle.setReason(.suggestion, active: false, hasPermission: true)

        XCTAssertFalse(lifecycle.ownsAcceptKeys)
        XCTAssertTrue(lifecycle.isTapEnabled, "The tap itself lingers so in-flight input is not dropped")
    }

    func test_losingPermissionEndsOwnershipEvenWithAReasonSet() {
        var lifecycle = interceptingForSuggestion()

        let effect = lifecycle.setReason(.emojiCapture, active: true, hasPermission: false)

        guard case .scheduleIdleCheck = effect else {
            return XCTFail("Expected an idle check, got \(effect)")
        }
        XCTAssertFalse(lifecycle.ownsAcceptKeys)
    }

    // MARK: - Lingering

    func test_idleCheckWaitsForQuietMeasuredFromTheLastKeystroke() {
        var lifecycle = interceptingForSuggestion()
        guard case .scheduleIdleCheck(let generation, let delay) =
            lifecycle.setReason(.suggestion, active: false, hasPermission: true) else {
            return XCTFail("Expected an idle check")
        }
        XCTAssertEqual(delay, AcceptTapLifecycle.idleDisableSeconds)

        // A keystroke half a second ago: 1.5 s of quiet still to go, and the tap stays enabled.
        let effect = lifecycle.idleCheckFired(generation: generation, hasPermission: true, lastKeyDownUptime: 99.5, nowUptime: 100)

        guard case .scheduleIdleCheck(generation, let remaining) = effect else {
            return XCTFail("Expected the check to be rescheduled, got \(effect)")
        }
        XCTAssertEqual(remaining, 1.5, accuracy: 1e-9)
        XCTAssertTrue(lifecycle.isTapEnabled)
    }

    func test_quietInputParksTheTapAndSchedulesItsRelease() {
        var lifecycle = interceptingForSuggestion()
        guard case .scheduleIdleCheck(let generation, _) =
            lifecycle.setReason(.suggestion, active: false, hasPermission: true) else {
            return XCTFail("Expected an idle check")
        }

        let effect = lifecycle.idleCheckFired(generation: generation, hasPermission: true, lastKeyDownUptime: 97, nowUptime: 100)

        XCTAssertEqual(
            effect,
            .park(disableTap: true, releaseGeneration: generation, delay: AcceptTapLifecycle.releaseDelaySeconds)
        )
        XCTAssertEqual(lifecycle.phase, .parked(generation: generation))
        XCTAssertFalse(lifecycle.isTapEnabled)
    }

    func test_staleIdleCheckIsIgnoredAfterTheTapWasRearmed() {
        var lifecycle = interceptingForSuggestion()
        guard case .scheduleIdleCheck(let stale, _) =
            lifecycle.setReason(.suggestion, active: false, hasPermission: true) else {
            return XCTFail("Expected an idle check")
        }
        _ = lifecycle.setReason(.suggestion, active: true, hasPermission: true)

        XCTAssertEqual(
            lifecycle.idleCheckFired(generation: stale, hasPermission: true, lastKeyDownUptime: nil, nowUptime: 100),
            Effect.none
        )
        XCTAssertEqual(lifecycle.phase, .intercepting)
    }

    func test_idleCheckFromAnEarlierHideCannotCutANewerQuietPeriodShort() {
        var lifecycle = interceptingForSuggestion()
        guard case .scheduleIdleCheck(let first, _) =
            lifecycle.setReason(.suggestion, active: false, hasPermission: true) else {
            return XCTFail("Expected an idle check")
        }
        _ = lifecycle.setReason(.suggestion, active: true, hasPermission: true)
        _ = lifecycle.setReason(.suggestion, active: false, hasPermission: true)

        XCTAssertEqual(
            lifecycle.idleCheckFired(generation: first, hasPermission: true, lastKeyDownUptime: nil, nowUptime: 100),
            Effect.none
        )
        XCTAssertTrue(lifecycle.isTapEnabled)
    }

    func test_idleCheckDoesNothingOnceAGrantMakesARememberedReasonCount() {
        var lifecycle = interceptingForSuggestion()
        // Permission is revoked while the suggestion reason is still set.
        guard case .scheduleIdleCheck(let generation, _) =
            lifecycle.setReason(.emojiCapture, active: false, hasPermission: false) else {
            return XCTFail("Expected an idle check")
        }

        XCTAssertEqual(
            lifecycle.idleCheckFired(generation: generation, hasPermission: true, lastKeyDownUptime: nil, nowUptime: 100),
            Effect.none
        )
        XCTAssertTrue(lifecycle.isTapEnabled)
    }

    // MARK: - Parked

    func test_rearmingAParkedTapReenablesItInsteadOfRecreatingIt() {
        var lifecycle = interceptingForSuggestion()
        _ = park(&lifecycle)

        XCTAssertEqual(
            lifecycle.setReason(.suggestion, active: true, hasPermission: true),
            .intercept(reenableParkedTap: true)
        )
        XCTAssertEqual(lifecycle.phase, .intercepting)
    }

    func test_releaseTimerRemovesAParkedTap() {
        var lifecycle = interceptingForSuggestion()
        let generation = park(&lifecycle)

        XCTAssertEqual(lifecycle.releaseFired(generation: generation, hasPermission: true), .release)
        XCTAssertEqual(lifecycle.phase, .absent)
    }

    func test_staleReleaseTimerCannotRemoveARearmedTap() {
        var lifecycle = interceptingForSuggestion()
        let stale = park(&lifecycle)
        _ = lifecycle.setReason(.suggestion, active: true, hasPermission: true)

        XCTAssertEqual(lifecycle.releaseFired(generation: stale, hasPermission: true), Effect.none)
        XCTAssertEqual(lifecycle.phase, .intercepting)
    }

    func test_aRedundantHideWhileParkedRestartsTheWaitButKeepsTheTapOff() {
        var lifecycle = interceptingForSuggestion()
        let parkedGeneration = park(&lifecycle)

        // Overlay state changes keep arriving while the user types with no ghost visible.
        guard case .scheduleIdleCheck(let generation, _) =
            lifecycle.setReason(.suggestion, active: false, hasPermission: true) else {
            return XCTFail("Expected the quiet-period wait to restart")
        }
        XCTAssertFalse(lifecycle.isTapEnabled)
        XCTAssertEqual(
            lifecycle.releaseFired(generation: parkedGeneration, hasPermission: true),
            Effect.none,
            "The earlier release must not fire mid-burst"
        )

        // Already disabled, so parking again must not toggle the tap a second time.
        XCTAssertEqual(
            lifecycle.idleCheckFired(generation: generation, hasPermission: true, lastKeyDownUptime: nil, nowUptime: 100),
            .park(disableTap: false, releaseGeneration: generation, delay: AcceptTapLifecycle.releaseDelaySeconds)
        )
        XCTAssertEqual(
            lifecycle.setReason(.suggestion, active: true, hasPermission: true),
            .intercept(reenableParkedTap: true)
        )
    }

    // MARK: - External teardown

    func test_tapRemovedKeepsReasonsButEndsOwnershipUntilTheNextReasonChange() {
        var lifecycle = interceptingForSuggestion()

        lifecycle.tapRemoved()

        XCTAssertEqual(lifecycle.phase, .absent)
        XCTAssertFalse(lifecycle.ownsAcceptKeys)
        XCTAssertEqual(lifecycle.reasons, [.suggestion])
        XCTAssertEqual(
            lifecycle.setReason(.suggestion, active: true, hasPermission: true),
            .intercept(reenableParkedTap: false)
        )
    }

    func test_droppingAReasonWithNoTapSchedulesNothing() {
        var lifecycle = AcceptTapLifecycle()

        XCTAssertEqual(lifecycle.setReason(.suggestion, active: false, hasPermission: true), Effect.none)
        XCTAssertEqual(lifecycle.phase, .absent)
    }

    // MARK: - Quiet-period arithmetic

    func test_idleRemainingIsMeasuredFromTheLastKeystroke() {
        XCTAssertEqual(AcceptTapLifecycle.idleRemaining(lastKeyDownUptime: nil, nowUptime: 100), 0)
        XCTAssertEqual(AcceptTapLifecycle.idleRemaining(lastKeyDownUptime: 99.5, nowUptime: 100), 1.5, accuracy: 1e-9)
        XCTAssertEqual(AcceptTapLifecycle.idleRemaining(lastKeyDownUptime: 97, nowUptime: 100), 0)
        // A keydown stamped after `now` (clock read ordering) must not shorten the quiet period.
        XCTAssertEqual(AcceptTapLifecycle.idleRemaining(lastKeyDownUptime: 100.2, nowUptime: 100), 2, accuracy: 1e-9)
    }
}
