import SwiftUI

/// File overview:
/// Renders the onboarding permission step with a centered, card-based layout.
///
/// Each permission is a glass-material card with an icon badge, title, short description, and
/// an Allow button or Done state. The view stays subscribed to live permission state so cards
/// update in real time as the user grants access through System Settings.
///
/// The onboarding list is derived from `TabbyPermissionKind.isRequiredForAutocomplete` so the
/// product's permission model and first-run UI cannot drift apart.
struct WelcomePermissionStepView: View {
    @ObservedObject var permissionManager: PermissionManager

    let permissionGuidanceController: PermissionGuidanceController
    let onBack: () -> Void
    let onContinue: () -> Void

    /// Only show permissions that block core autocomplete.
    private var onboardingPermissions: [TabbyPermissionKind] {
        TabbyPermissionKind.allCases.filter(\.isRequiredForAutocomplete)
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("Enable tabby")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Grant permissions so tabby can\nread text, capture context, and accept completions.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ForEach(onboardingPermissions) { permission in
                    PermissionCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        permissionGuidanceController: permissionGuidanceController
                    )
                }
            }

            WelcomeNavigation(
                canGoBack: true,
                canContinue: permissionManager.requiredPermissionsGranted,
                disabledHint: "Grant all permissions to continue.",
                onBack: onBack,
                onContinue: onContinue
            )
        }
        .onDisappear {
            permissionGuidanceController.dismiss()
        }
    }
}

// MARK: - Permission Card

/// One permission row rendered as a glass-material card.
///
/// The card measures its own button frame in screen coordinates because the permission guidance
/// controller needs a global rect to anchor its drag-helper animation. That screen-space concern
/// stays here in the view rather than leaking into the controller.
private struct PermissionCard: View {
    let permission: TabbyPermissionKind
    let granted: Bool
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 14) {
            PermissionIconBadge(
                systemImage: permission.systemImageName,
                granted: granted
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.system(size: 14, weight: .medium))

                Text(permission.onboardingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if granted {
                PermissionDoneBadge()
            } else {
                Button("Allow") {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Small Components

/// Tinted SF Symbol inside a rounded badge, similar to Apple's settings icon style.
private struct PermissionIconBadge: View {
    let systemImage: String
    let granted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(granted ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.12))

            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(granted ? .green : .accentColor)
        }
        .frame(width: 32, height: 32)
    }
}

/// Green checkmark with "Done" label shown after a permission is granted.
private struct PermissionDoneBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))

            Text("Done")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.green)
    }
}
