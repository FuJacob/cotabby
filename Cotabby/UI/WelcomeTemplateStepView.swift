import SwiftUI

/// File overview:
/// The onboarding step where the user picks one of three starting points (Quick / Everyday /
/// Powerful). Selecting a card applies its settings and, for local-model templates, kicks off the
/// model download in the background so it can finish while the user completes the rest of onboarding.
///
/// This view is intentionally render-only: it reports the chosen template upward via `onSelect` and
/// the parent (`WelcomeView`) owns applying settings and starting downloads. Per-card recommendation,
/// gating, and warning copy come from `OnboardingTemplateRecommender` so the product rules live in
/// one testable place.
struct WelcomeTemplateStepView: View {
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService

    let hardware: HardwareCapability
    let selectedEngine: SuggestionEngineKind
    @Binding var selectedTemplate: OnboardingTemplate?
    let onSelectEngine: (SuggestionEngineKind) -> Void
    let onSelect: (OnboardingTemplate) -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose a starting point")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Pick one to get set up. You can fine-tune everything later in Settings.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            engineSelector

            VStack(spacing: 10) {
                ForEach(OnboardingTemplate.allCases) { template in
                    let availability = OnboardingTemplateRecommender.availability(
                        for: template,
                        hardware: hardware,
                        engine: selectedEngine
                    )
                    let plan = OnboardingTemplateRecommender.resolvePlan(
                        for: template,
                        engine: selectedEngine
                    )

                    TemplateCard(
                        template: template,
                        plan: plan,
                        availability: availability,
                        isSelected: selectedTemplate == template,
                        downloadState: downloadState(for: plan),
                        onTap: { onSelect(template) }
                    )
                }
            }
        }
    }

    /// The top-level engine choice: the two cards that decide whether every tier below runs on
    /// Apple Intelligence or a local open-source model. Apple Intelligence is disabled (with the
    /// availability reason as its subtitle) when the Mac cannot run it.
    private var engineSelector: some View {
        let appleAvailable = foundationModelAvailabilityService.isAvailable
        return HStack(spacing: 10) {
            EngineChoiceCard(
                title: SuggestionEngineKind.appleIntelligence.displayLabel,
                subtitle: appleAvailable
                    ? "Built into macOS"
                    : foundationModelAvailabilityService.userVisibleMessage,
                systemImageName: "apple.logo",
                isSelected: selectedEngine == .appleIntelligence,
                isDisabled: !appleAvailable,
                onTap: { onSelectEngine(.appleIntelligence) }
            )

            EngineChoiceCard(
                title: SuggestionEngineKind.llamaOpenSource.displayLabel,
                subtitle: "Local models on your Mac",
                systemImageName: "internaldrive",
                isSelected: selectedEngine == .llamaOpenSource,
                isDisabled: false,
                onTap: { onSelectEngine(.llamaOpenSource) }
            )
        }
    }

    /// The install/download state for a plan's model, or `nil` for Apple Intelligence plans that
    /// never download anything.
    private func downloadState(for plan: ResolvedTemplatePlan) -> ModelDownloadState? {
        guard let model = plan.modelToDownload else {
            return nil
        }
        return modelDownloadManager.state(for: model)
    }
}

// MARK: - Template Card

private struct TemplateCard: View {
    let template: OnboardingTemplate
    let plan: ResolvedTemplatePlan
    let availability: OnboardingTemplateAvailability
    let isSelected: Bool
    let downloadState: ModelDownloadState?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    iconBadge

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(template.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(availability.isDisabled ? .tertiary : .primary)

                            if availability.isRecommended {
                                RecommendedBadge()
                            }
                        }

                        Text(template.tagline)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if isSelected && !availability.isDisabled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.accentColor)
                    }
                }

                Text(template.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: engineSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Text(engineLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                if let warning = availability.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(availability.isDisabled ? Color.secondary : Color.orange)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isSelected, let downloadState {
                    downloadStatusView(downloadState)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected && !availability.isDisabled
                            ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                        lineWidth: isSelected && !availability.isDisabled ? 1.5 : 0.5
                    )
            )
            .opacity(availability.isDisabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(availability.isDisabled)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                    : AnyShapeStyle(.quaternary.opacity(0.5)))

            Image(systemName: template.systemImageName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected && !availability.isDisabled ? Color.accentColor : .secondary)
        }
        .frame(width: 38, height: 38)
    }

    private var engineSymbol: String {
        plan.engine == .appleIntelligence ? "apple.logo" : "internaldrive"
    }

    private var engineLabel: String {
        switch plan.engine {
        case .appleIntelligence:
            return "Apple Intelligence · built into macOS"
        case .llamaOpenSource:
            let size = plan.modelToDownload?.approximateSizeLabel ?? ""
            return "Local model · \(size) download"
        }
    }

    @ViewBuilder
    private func downloadStatusView(_ state: ModelDownloadState) -> some View {
        switch state {
        case .idle:
            // Selected but the download hasn't been kicked off yet (transient); show a neutral hint.
            Text("Preparing download…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    // No fraction reported yet: fall back to the default (circular) spinner, since
                    // macOS's linear style renders nothing for an indeterminate ProgressView.
                    ProgressView()
                }
                Text(state.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .downloaded:
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Engine Choice Card

/// One of the two top-level engine cards (Apple Intelligence / Open Source). Visually lighter than
/// `TemplateCard` so the tier cards below stay the primary focus, but selectable in the same way.
private struct EngineChoiceCard: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    let isSelected: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: systemImageName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(iconStyle)

                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isDisabled ? .tertiary : .primary)

                    Spacer(minLength: 0)

                    if isSelected && !isDisabled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.accentColor)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected && !isDisabled
                            ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08),
                        lineWidth: isSelected && !isDisabled ? 1.5 : 0.5
                    )
            )
            .opacity(isDisabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var iconStyle: HierarchicalShapeStyle {
        // `.primary` when selected reads as active without introducing a second accent color.
        isSelected && !isDisabled ? .primary : .secondary
    }
}

// MARK: - Recommended Badge

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.12))
            )
    }
}
