import SwiftUI

/// File overview:
/// Renders the onboarding permission step: a header, one card per permission, and a privacy
/// footnote. Each permission is a card with a tinted icon tile, title, short description, and an
/// Allow button that springs into a green Done state the moment macOS reports the grant. The view
/// stays subscribed to live permission state so cards update in real time as the user grants
/// access through System Settings.
///
/// Navigation (Back/Continue) is owned by `WelcomeView`'s pinned footer rather than this view, so
/// the Continue button can never scroll off-screen behind tall content. The cards themselves are
/// the shared `OnboardingPermissionList`; the Continue gate only looks at required permissions.
struct WelcomePermissionStepView: View {
    @ObservedObject var permissionManager: PermissionManager

    let permissionGuidanceController: PermissionGuidanceController

    var body: some View {
        VStack(spacing: 24) {
            OnboardingStepHeader(
                systemImage: "lock.shield.fill",
                title: "Two quick permissions",
                subtitle: "Cotabby needs to read the field you're typing in and watch for the accept key.\n"
                    + "The optional one unlocks smarter, screen-aware suggestions."
            )
            .onboardingReveal(0)

            OnboardingPermissionList(
                permissionManager: permissionManager,
                emphasis: .setup,
                permissionGuidanceController: permissionGuidanceController
            )

            // The trust line carries onboarding's core privacy promise; it sits with the
            // permission asks because this is the moment the user is deciding whether to trust us.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .medium))

                Text(
                    "Apple Intelligence and Open Source run on your Mac. " +
                        "If you choose an endpoint, enabled text context is sent to that server."
                )
                    .font(.system(size: 12, design: .rounded))
            }
            .foregroundStyle(.tertiary)
            .onboardingReveal(OnboardingPermissionList.revealIndexAfterList + 1)
        }
        .onDisappear {
            permissionGuidanceController.dismiss()
        }
    }
}
