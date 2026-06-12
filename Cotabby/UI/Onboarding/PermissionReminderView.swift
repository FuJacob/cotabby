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

            VStack(spacing: 10) {
                ForEach(
                    Array(CotabbyPermissionKind.allCases.filter(\.isRequiredForAutocomplete).enumerated()),
                    id: \.element
                ) { index, permission in
                    ReminderPermissionCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        permissionGuidanceController: permissionGuidanceController
                    )
                    .onboardingReveal(1 + index)
                }

                // Optional enhancements (Screen Recording) render after the required cards, tagged
                // so they read as a discoverable extra rather than a blocker. The "I'll do this
                // later" / "Done" button is gated on required permissions only, so these never hold
                // it up.
                ForEach(
                    Array(CotabbyPermissionKind.allCases.filter(\.isOptionalEnhancement).enumerated()),
                    id: \.element
                ) { index, permission in
                    ReminderPermissionCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        isOptional: true,
                        permissionGuidanceController: permissionGuidanceController
                    )
                    .onboardingReveal(3 + index)
                }
            }

            WelcomeButton(title: permissionManager.requiredPermissionsGranted ? "Done" : "I'll do this later") {
                onDismiss()
            }
            .onboardingReveal(4)
        }
        .padding(36)
        .frame(width: 540)
        .background(OnboardingBackdrop())
    }
}

/// Permission card for the reminder view. Same card chrome as onboarding, but a missing required
/// permission goes orange so the row reads as "broken, fix me" rather than a neutral setup task.
private struct ReminderPermissionCard: View {
    let permission: CotabbyPermissionKind
    let granted: Bool
    var isOptional = false
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame = CGRect.zero

    /// Tile tint: orange flags the broken/required state; optional and granted rows keep the same
    /// identity tints used during onboarding so the surfaces stay recognizably one system.
    private var tileTint: Color {
        if granted || isOptional {
            return permission.onboardingTint
        }
        return .orange
    }

    var body: some View {
        HStack(spacing: 14) {
            OnboardingIconTile(systemImage: permission.systemImageName, tint: tileTint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))

                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(permission.onboardingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if granted {
                PermissionDoneBadge()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if isOptional {
                // Same "Allow" verb as the required rows (never a "feature toggle" like Enable),
                // but a lower-emphasis bordered button so the optional row never competes visually
                // with the required Allow buttons above it in this "Permissions needed" modal.
                Button("Allow") {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            } else {
                Button("Allow") {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: granted)
    }
}
