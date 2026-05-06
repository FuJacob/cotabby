import AppKit
import SwiftUI

/// File overview:
/// Renders the first-run onboarding wizard as a five-step flow:
/// welcome -> profile -> permissions -> choose model -> ready.
///
/// The engine and model download screens are merged into one step with progressive disclosure:
/// selecting the open-source engine expands its card to reveal downloadable models inline.
/// Each step earns its screen by teaching one thing or collecting one decision.
struct WelcomeView: View {
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    let permissionGuidanceController: PermissionGuidanceController
    let onPreferredWindowSizeChange: (NSSize) -> Void
    let onDismiss: () -> Void

    @State private var step: WelcomeStep = .welcome

    /// The window should follow the active screen instead of staying pinned to the tallest step.
    /// This keeps small steps like "You're all set" feeling intentional rather than like empty
    /// modal shells that inherited the model-picker's height.
    private var preferredWindowSize: NSSize {
        step.preferredWindowSize(selectedEngine: suggestionSettings.selectedEngine)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            switch step {
            case .welcome:
                welcomeStep
            case .profile:
                profileStep
            case .permissions:
                permissionsStep
            case .chooseModel:
                chooseModelStep
            case .done:
                doneStep
            }

            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(width: preferredWindowSize.width)
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.25), value: preferredWindowSize)
        .onAppear {
            onPreferredWindowSizeChange(preferredWindowSize)
        }
        .onChange(of: preferredWindowSize) { _, newValue in
            onPreferredWindowSizeChange(newValue)
        }
    }
}

// MARK: - Steps

private enum WelcomeStep: Int, Comparable {
    case welcome
    case profile
    case permissions
    case chooseModel
    case done

    static func < (lhs: WelcomeStep, rhs: WelcomeStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// These sizes are product decisions rather than pure layout math.
    /// The coordinator uses them to animate the AppKit window, while SwiftUI uses the width so the
    /// content and the host window stay in sync.
    func preferredWindowSize(selectedEngine: SuggestionEngineKind) -> NSSize {
        switch self {
        case .welcome:
            return NSSize(width: 500, height: 320)
        case .profile:
            return NSSize(width: 540, height: 420)
        case .permissions:
            return NSSize(width: 540, height: 480)
        case .chooseModel:
            if selectedEngine == .llamaOpenSource {
                return NSSize(width: 540, height: 520)
            }

            return NSSize(width: 540, height: 360)
        case .done:
            return NSSize(width: 500, height: 340)
        }
    }
}

// MARK: - Step 1: Welcome

extension WelcomeView {
    fileprivate var welcomeStep: some View {
        VStack(spacing: 24) {
            // Onboarding should show the exported product mark, not the AppKit-derived runtime icon.
            // `NSApp.applicationIconImage` can pick up the newer glass treatment, which makes the
            // welcome screen drift from the branded artwork users see elsewhere.
            Image("WelcomeAppIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            VStack(spacing: 8) {
                Text("Welcome to tabby")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("AI autocomplete in any text field, all done locally.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            WelcomeButton(title: "Get Started") {
                step = .profile
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Step 2: Profile

extension WelcomeView {
    fileprivate var profileStep: some View {
        WelcomeProfileStepView(
            suggestionSettings: suggestionSettings,
            onBack: { step = .welcome },
            onContinue: { step = .permissions }
        )
    }
}

// MARK: - Step 3: Permissions

extension WelcomeView {
    fileprivate var permissionsStep: some View {
        WelcomePermissionStepView(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            onBack: { step = .profile },
            onContinue: { step = .chooseModel }
        )
    }
}

// MARK: - Step 4: Choose Model (combined engine + model)

extension WelcomeView {
    fileprivate var chooseModelStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose a Model")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Pick how tabby generates completions.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                appleIntelligenceCard
                llamaOpenSourceCard
            }

            WelcomeNavigation(
                canGoBack: true,
                canContinue: canContinueFromModelStep,
                disabledHint: modelStepDisabledHint,
                onBack: { step = .permissions },
                onContinue: { step = .done }
            )
        }
    }

    fileprivate var appleIntelligenceCard: some View {
        let isSelected = suggestionSettings.selectedEngine == .appleIntelligence
        let isAvailable = foundationModelAvailabilityService.isAvailable

        return EngineCard(
            artworkName: "apple_intelligence",
            title: "Apple Intelligence",
            subtitle: isAvailable
                ? "Built into macOS. No download needed."
                : "Requires Apple Silicon and macOS 26.",
            isSelected: isSelected && isAvailable,
            isAvailable: isAvailable
        ) {
            suggestionSettings.selectEngine(.appleIntelligence)
        }
    }

    fileprivate var llamaOpenSourceCard: some View {
        let isSelected = suggestionSettings.selectedEngine == .llamaOpenSource

        return VStack(spacing: 0) {
            EngineCard(
                artworkName: "llama",
                title: "Open Source",
                subtitle: "Runs locally on this Mac. Download a model to get started.",
                isSelected: isSelected,
                isAvailable: true
            ) {
                suggestionSettings.selectEngine(.llamaOpenSource)
            }

            if isSelected {
                VStack(spacing: 0) {
                    Divider()
                        .padding(.horizontal, 18)

                    DownloadableModelCatalogView(
                        modelDownloadManager: modelDownloadManager,
                        onRefreshModels: {
                            modelDownloadManager.refreshModelStates()
                            runtimeModel.refreshAvailableModels()
                        }
                    )
                    .padding(18)
                }
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 16,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(.regularMaterial.opacity(0.5))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.spring(duration: 0.3), value: isSelected)
    }

    fileprivate var canContinueFromModelStep: Bool {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            return foundationModelAvailabilityService.isAvailable
        case .llamaOpenSource:
            return hasAtLeastOneModel
        }
    }

    fileprivate var modelStepDisabledHint: String {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            return "Apple Intelligence is not available on this Mac."
        case .llamaOpenSource:
            return "Add or download at least one model to continue."
        }
    }

    fileprivate var hasAtLeastOneModel: Bool {
        modelDownloadManager.models.contains { model in
            modelDownloadManager.state(for: model) == .downloaded
        } || !runtimeModel.availableModels.isEmpty
    }
}

// MARK: - Step 4: Done

extension WelcomeView {
    fileprivate var doneStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(.green.opacity(0.12))
                    .shadow(color: .green.opacity(0.08), radius: 8, y: 2)

                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("Start typing anywhere.\nPress Tab to accept.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .foregroundStyle(.tertiary)

                Text("Find tabby in your menu bar.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            WelcomeButton(title: "Start Using tabby") {
                onDismiss()
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Engine Card

/// Selectable engine card with glass-material background.
/// When selected, shows an accent-tinted border and checkmark. When unavailable, dims the content.
private struct EngineCard: View {
    let artworkName: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(
            action: {
                if isAvailable {
                    action()
                }
            },
            label: {
                HStack(spacing: 14) {
                    EngineArtworkThumbnail(
                        artworkName: artworkName,
                        isSelected: isSelected,
                        isAvailable: isAvailable
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isAvailable ? .primary : .tertiary)

                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if isSelected && isAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.accentColor)
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
                        .stroke(
                            isSelected && isAvailable
                                ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.08),
                            lineWidth: isSelected && isAvailable ? 1.5 : 0.5
                        )
                )
            }
        )
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

/// Purpose-built thumbnail tile for onboarding engine artwork.
/// We use `scaledToFill` inside a fixed rounded frame so square and landscape assets can share
/// one card layout while still cropping intentionally instead of shrinking into an icon box.
private struct EngineArtworkThumbnail: View {
    let artworkName: String
    let isSelected: Bool
    let isAvailable: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isSelected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                        : AnyShapeStyle(.quaternary.opacity(0.45))
                )

            Image(artworkName)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 76, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isAvailable ? 1.0 : 0.55)
        }
        .frame(width: 76, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected && isAvailable
                        ? Color.accentColor.opacity(0.22)
                        : Color.white.opacity(0.08),
                    lineWidth: isSelected && isAvailable ? 1.0 : 0.5
                )
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Shared Components

/// Primary action button used on the welcome and done steps.
struct WelcomeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// Continue navigation bar for middle wizard steps.
/// "Continue" can be disabled with a tooltip hint explaining what's needed.
struct WelcomeNavigation: View {
    var canGoBack: Bool = false
    var canContinue: Bool = true
    var disabledHint: String?
    var onBack: (() -> Void)?
    let onContinue: () -> Void

    var body: some View {
        HStack {
            if canGoBack, let onBack {
                Button("Back") {
                    onBack()
                }
                .controlSize(.large)
            }

            Spacer(minLength: 0)

            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .help(canContinue ? "" : (disabledHint ?? ""))
        }
    }
}
