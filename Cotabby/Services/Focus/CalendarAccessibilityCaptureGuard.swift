import AppKit
import Foundation
import Logging

/// Owns the short-lived Calendar date/time interaction state used by `FocusTracker`'s capture gate.
///
/// `InputMonitor` supplies global pointer-down coordinates. This service first checks the frontmost
/// bundle (so normal clicks pay no AX cost), hit-tests only Calendar, and reduces the clicked AX
/// element through `CalendarAccessibilityCapturePolicy`. `CotabbyAppEnvironment` owns one instance
/// for the app lifetime and the focus model reads its current state before any candidate-tree walk.
@MainActor
final class CalendarAccessibilityCaptureGuard {
    private var isDateTimeInteractionActive = false

    /// Updates the guard from a Quartz/global screen point (top-left origin).
    func handlePointerDown(atAccessibilityPoint point: CGPoint) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == CalendarAccessibilityCapturePolicy.calendarBundleIdentifier else {
            updateSuppression(false)
            return
        }

        guard let target = AXHelper.element(atAccessibilityPoint: point) else {
            return
        }

        let targetApplication = AXHelper.owningApplication(of: target)
        let nextState = CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
            currentlySuppressed: isDateTimeInteractionActive,
            targetBundleIdentifier: targetApplication?.bundleIdentifier,
            targetRole: AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: target),
            targetIdentifier: AXHelper.accessibilityIdentifier(of: target)
        )
        updateSuppression(nextState)
    }

    /// `FocusTracker` calls this after its cheap focused-element lookup and before resolver traversal.
    func shouldSuppressCapture(for bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == CalendarAccessibilityCapturePolicy.calendarBundleIdentifier else {
            // App switches can happen by keyboard with no pointer event. Clearing here prevents a
            // stale Calendar interaction from suppressing capture when the user later switches back.
            updateSuppression(false)
            return false
        }
        return isDateTimeInteractionActive
    }

    private func updateSuppression(_ shouldSuppress: Bool) {
        guard shouldSuppress != isDateTimeInteractionActive else {
            return
        }
        isDateTimeInteractionActive = shouldSuppress
        if shouldSuppress {
            CotabbyLogger.focus.info("Paused Calendar AX capture for date/time editing")
        } else {
            CotabbyLogger.focus.info("Resumed Calendar AX capture after date/time editing")
        }
    }
}
