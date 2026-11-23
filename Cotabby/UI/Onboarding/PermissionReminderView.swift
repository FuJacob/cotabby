import SwiftUI

/// File overview:
/// Shown on launch when the user previously completed onboarding but one or more required
/// permissions are missing. This happens after a permission-prompted restart or if the user
/// revokes a permission later in System Settings.
///
/// Shares onboarding's design system (`OnboardingStyle`) so the two windows read as one product,
/// but with urgency semantics layered on: a required-and-missing permission shows an orange tile
/// and an orange Allow button, while granted rows relax back to their identity tint.
struct PermissionReminderView: View {
    @ObservedObject var permissionManager: PermissionManager

    let permissionGuidanceController: PermissionGuidanceController
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            OnboardingStepHeader(
                systemImage: "exclamationmark.shield.fill",
                tint: .orange,
                title: "Permissions needed",
                subtitle: "Cotabby needs these permissions to work.\nGrant them in System Settings, then come back here."
            )
            .onboardingReveal(0)

            // The "I'll do this later" / "Done" button below is gated on required permissions only,
            // so the optional cards never hold it up.
            OnboardingPermissionList(
                permissionManager: permissionManager,
                emphasis: .reminder,
                permissionGuidanceController: permissionGuidanceController
            )

            WelcomeButton(title: permissionManager.requiredPermissionsGranted ? "Done" : "I'll do this later") {
                onDismiss()
            }
            .onboardingReveal(OnboardingPermissionList.revealIndexAfterList)
        }
        .padding(36)
        .frame(width: 540)
        .background(OnboardingBackdrop())
    }
}
