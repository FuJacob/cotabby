import XCTest
@testable import Cotabby

/// Pins the week-later reminder: it waits a full week from the stamped start, only appears while
/// macOS inline predictions are still on, and never comes back once dismissed.
@MainActor
final class InlinePredictionNudgeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "InlinePredictionNudgeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPolicyWaitsAWeekAndRespectsSwitchAndDismissal() {
        let week = InlinePredictionNudge.delay
        func show(after elapsed: TimeInterval, dismissed: Bool = false, enabled: Bool = true) -> Bool {
            InlinePredictionNudge.shouldShow(
                startDate: start,
                now: start.addingTimeInterval(elapsed),
                isDismissed: dismissed,
                isPredictionEnabled: enabled
            )
        }

        XCTAssertFalse(show(after: week - 60), "Not before a full week")
        XCTAssertTrue(show(after: week))
        XCTAssertFalse(show(after: week, enabled: false), "Nothing to suggest once the switch is off")
        XCTAssertFalse(show(after: week, dismissed: true), "Dismissed for good")
        XCTAssertFalse(
            InlinePredictionNudge.shouldShow(startDate: nil, now: start, isDismissed: false, isPredictionEnabled: true),
            "No stamp yet means the clock has not started"
        )
    }

    func testStartIsStampedOnceAndKeptOnLaterLaunches() {
        InlinePredictionNudge.recordStartIfNeeded(userDefaults: defaults, now: start)
        InlinePredictionNudge.recordStartIfNeeded(userDefaults: defaults, now: start.addingTimeInterval(3600))
        XCTAssertEqual(defaults.object(forKey: InlinePredictionNudge.startDateKey) as? Date, start)
    }

    func testCardFollowsSystemSwitchAndStaysGoneAfterDismissal() {
        var systemValue = true
        let monitor = SystemInlinePredictionMonitor(readIsEnabled: { systemValue }, notificationCenter: NotificationCenter())
        InlinePredictionNudge.recordStartIfNeeded(userDefaults: defaults, now: start)
        let nudge = InlinePredictionNudge(
            monitor: monitor,
            userDefaults: defaults,
            now: { self.start.addingTimeInterval(InlinePredictionNudge.delay + 1) }
        )
        XCTAssertTrue(nudge.isVisible)

        systemValue = false
        nudge.refresh()
        XCTAssertFalse(nudge.isVisible, "Turning the switch off hides the card")

        systemValue = true
        nudge.refresh()
        XCTAssertTrue(nudge.isVisible)

        nudge.dismiss()
        nudge.refresh()
        XCTAssertFalse(nudge.isVisible, "No Thanks is permanent")
    }
}
