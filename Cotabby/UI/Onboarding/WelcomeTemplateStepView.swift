import SwiftUI

/// File overview:
/// The onboarding step where the user picks one of three starting points (Quick / Everyday /
/// Powerful). Selecting a card applies its settings and, for local-model templates, kicks off the
/// model download in the background so it can finish while the user completes the rest of
/// onboarding.
///
/// This view is intentionally render-only: it reports the chosen template upward via `onSelect` and
/// the parent (`WelcomeView`) owns applying settings and starting downloads. Per-card
/// recommendation, gating, and warning copy come from `OnboardingTemplateRecommender` so the
/// product rules live in one testable place.
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
            OnboardingStepHeader(
                systemImage: "wand.and.stars",
                title: "Choose a starting point",
                subtitle: "Pick one to get set up. You can fine-tune everything later in Settings."
            )
            .onboardingReveal(0)

            engineSelector
                .onboardingReveal(1)

            VStack(spacing: 10) {
                ForEach(Array(OnboardingTemplate.curatedTiers.enumerated()), id: \.element) { index, template in
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
                    .onboardingReveal(2 + index)
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
                systemImageName: SuggestionEngineKind.appleIntelligence.systemImageName,
                isSelected: selectedEngine == .appleIntelligence,
                isDisabled: !appleAvailable,
                onTap: { onSelectEngine(.appleIntelligence) }
            )

            EngineChoiceCard(
                title: SuggestionEngineKind.llamaOpenSource.displayLabel,
                subtitle: "Local models on your Mac",
                systemImageName: SuggestionEngineKind.llamaOpenSource.systemImageName,
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

// MARK: - Tier tint

extension OnboardingTemplate {
    /// Per-tier tile tint, defined in the UI layer so the model type stays free of SwiftUI.
    /// Green / brand blue / purple gives the three cards distinct, scannable identities.
    var onboardingTint: Color {
        switch self {
        case .quick:
            .green
        case .everyday:
            CotabbyBrand.accent
        case .powerful:
            .purple
        case .custom:
            .gray
        }
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

    /// Each card tracks its own disclosure state so opening one doesn't expand the others.
    /// Collapsed by default — users who trust the recommendation should never have to see the
    /// row list, and short cards preserve the "pick one" feel of this step.
    @State private var isFeatureListExpanded = false

    private var isActive: Bool {
        isSelected && !availability.isDisabled
    }

    var body: some View {
        VStack(spacing: 0) {
            selectionButton
            featureDisclosure
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(
                        color: isActive ? CotabbyBrand.accent.opacity(0.18) : .black.opacity(0.07),
                        radius: isActive ? 7 : 3,
                        y: 1
                    )

                // A faint brand wash over the material marks the chosen card even at a glance from
                // across the room; the stroke alone is too subtle once three cards are stacked.
                if isActive {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CotabbyBrand.accent.opacity(0.06))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isActive ? CotabbyBrand.accent.opacity(0.55) : Color.primary.opacity(0.07),
                    lineWidth: isActive ? 1.5 : 0.5
                )
        )
        .opacity(availability.isDisabled ? 0.55 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
    }

    /// Main card surface that selects the template. The feature disclosure is rendered as a sibling
    /// view below this button so its toggle taps never double-fire selection.
    private var selectionButton: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    OnboardingIconTile(
                        systemImage: template.systemImageName,
                        tint: availability.isDisabled ? .gray : template.onboardingTint,
                        size: 38
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(template.title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
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

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(CotabbyBrand.accent)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(availability.isDisabled)
    }

    /// Collapsible "what's included" section. Rendering it outside the selection button keeps the
    /// expand/collapse tap target separate so opening the list doesn't change the selected card.
    private var featureDisclosure: some View {
        let rows = OnboardingTemplateFeatureList.rows(for: template)
        return VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.4)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isFeatureListExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(isFeatureListExpanded ? "Hide details" : "What's included")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFeatureListExpanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isFeatureListExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        featureRowView(row)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func featureRowView(_ row: OnboardingTemplateFeatureRow) -> some View {
        HStack(spacing: 8) {
            featureRowIcon(for: row.value)
                .frame(width: 14, alignment: .center)

            Text(row.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if case .detail(let value) = row.value {
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func featureRowIcon(for value: OnboardingTemplateFeatureValue) -> some View {
        switch value {
        case .enabled:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CotabbyBrand.accent)
        case .disabled:
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        case .detail:
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private var engineSymbol: String {
        plan.engine.systemImageName
    }

    private var engineLabel: String {
        switch plan.engine {
        case .appleIntelligence:
            return "Apple Intelligence · built into macOS"
        case .llamaOpenSource:
            guard let model = plan.modelToDownload else { return "Local model" }
            return "\(model.displayName) · \(model.approximateSizeLabel) download"
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
                        .tint(CotabbyBrand.accent)
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

    private var isActive: Bool {
        isSelected && !isDisabled
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: systemImageName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? AnyShapeStyle(CotabbyBrand.accent) : AnyShapeStyle(.secondary))

                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(isDisabled ? .tertiary : .primary)

                    Spacer(minLength: 0)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(CotabbyBrand.accent)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)

                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(CotabbyBrand.accent.opacity(0.07))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? CotabbyBrand.accent.opacity(0.55) : Color.primary.opacity(0.07),
                        lineWidth: isActive ? 1.5 : 0.5
                    )
            )
            .opacity(isDisabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
    }
}

// MARK: - Recommended Badge

private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [CotabbyBrand.accentSoft, CotabbyBrand.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
    }
}
