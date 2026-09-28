import Foundation

/// File overview:
/// Decides when the system-wide focused Accessibility element should be ignored in favor of the
/// frontmost application's own focused element.
///
/// macOS system UI agents (privacy prompts from `UserNotificationCenter`, notification banners,
/// Control Center) can own the system-wide focused element while the user keeps typing into the
/// frontmost app. Trusting that element verbatim reports "no focused text input" for as long as the
/// alert is on screen, which silently switches autocomplete off in every host. Measured 2026-09: a
/// Documents-folder privacy prompt held `AXFocusedUIElement` for minutes while TextEdit was
/// frontmost and receiving keystrokes.
///
/// Accessory launchers (Spotlight, Raycast, Alfred) also own focus while another app is frontmost,
/// but there the user really is typing into the accessory, so those stay trusted: only the named
/// system agents are shadowed.
nonisolated enum SystemUIFocusShadowPolicy {
    /// Bundle identifiers of system agents whose focused element never describes the user's text
    /// field. Lowercased; matched case-insensitively.
    private static let shadowingBundleIdentifiers: Set<String> = [
        "com.apple.usernotificationcenter",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    /// True when the element owned by `owningBundleIdentifier` should be ignored and the frontmost
    /// application (`frontmostBundleIdentifier`) queried instead. Never shadows when the agent is
    /// itself frontmost (the user is interacting with the alert) or when the two are the same app.
    static func shouldPreferFrontmostApplication(
        owningBundleIdentifier: String?,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard let owner = owningBundleIdentifier?.lowercased(),
              let frontmost = frontmostBundleIdentifier?.lowercased(),
              owner != frontmost
        else {
            return false
        }
        return shadowingBundleIdentifiers.contains(owner)
    }
}
