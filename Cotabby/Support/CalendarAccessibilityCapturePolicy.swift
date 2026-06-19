import ApplicationServices
import Foundation

/// Pure state transition for Apple Calendar's fragile date/time editor.
///
/// Calendar keeps the previously focused text field as first responder while its date/time section
/// is open. Reading that stale field's broader Accessibility neighborhood makes Calendar collapse
/// the section and move focus to another editor row. The policy therefore enters suppression only
/// for date/time controls and leaves it only when the pointer reaches a real text input or another
/// application. Keeping this rule pure makes the compatibility behavior testable without a live AX
/// tree; `CalendarAccessibilityCaptureGuard` owns the OS hit-testing boundary.
enum CalendarAccessibilityCapturePolicy {
    static let calendarBundleIdentifier = "com.apple.iCal"

    private static let dateTimeControlIdentifiers: Set<String> = [
        "date-time-button",
        "start-datepicker",
        "start-timepicker",
        "end-datepicker",
        "end-timepicker"
    ]

    private static let editableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXSearchField",
        kAXComboBoxRole as String
    ]

    /// Computes the guard's next state for one physical pointer-down target.
    ///
    /// While suppression is active, unknown Calendar controls keep it active. Date picker popups
    /// expose several private button roles with unstable identifiers, so treating an unknown click
    /// as "resume" would reintroduce the bug on the user's next date selection. A click into any
    /// editable text role is an explicit safe boundary and resumes normal autocomplete capture.
    static func shouldSuppressCapture(
        currentlySuppressed: Bool,
        targetBundleIdentifier: String?,
        targetRole: String?,
        targetIdentifier: String?
    ) -> Bool {
        guard targetBundleIdentifier == calendarBundleIdentifier else {
            return false
        }

        if targetRole == "AXDateTimeArea"
            || targetIdentifier.map(dateTimeControlIdentifiers.contains) == true {
            return true
        }

        if targetRole.map(editableTextRoles.contains) == true {
            return false
        }

        return currentlySuppressed
    }
}
