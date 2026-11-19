import AppKit
import XCTest
@testable import Cotabby

/// Pins the onboarding hint's data source: it reflects the system switch at creation, follows it when
/// Cotabby becomes active again, and links to Keyboard settings.
@MainActor
final class SystemInlinePredictionMonitorTests: XCTestCase {
    func testReadsStateAtCreation() {
        XCTAssertTrue(SystemInlinePredictionMonitor(readIsEnabled: { true }, notificationCenter: NotificationCenter()).isEnabled)
        XCTAssertFalse(SystemInlinePredictionMonitor(readIsEnabled: { false }, notificationCenter: NotificationCenter()).isEnabled)
    }

    func testRefreshesWhenAppBecomesActive() {
        var systemValue = true
        let center = NotificationCenter()
        let monitor = SystemInlinePredictionMonitor(readIsEnabled: { systemValue }, notificationCenter: center)
        XCTAssertTrue(monitor.isEnabled)

        // The user turns the switch off in System Settings and returns to Cotabby.
        systemValue = false
        XCTAssertTrue(monitor.isEnabled, "Nothing changes until Cotabby is active again")
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(monitor.isEnabled)
    }

    func testKeyboardSettingsURLTargetsKeyboardPane() {
        XCTAssertEqual(
            SystemInlinePredictionMonitor.keyboardSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        )
    }
}
