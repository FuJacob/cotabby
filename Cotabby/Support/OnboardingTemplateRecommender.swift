import Foundation

/// File overview:
/// Pure rules that turn an `OnboardingTemplate` into a concrete plan and decide which templates to
/// recommend, warn about, or disable on a given Mac. All functions are deterministic over their
/// inputs (`HardwareCapability`, Apple Intelligence availability) so the onboarding UI can stay a
/// thin renderer and the decisions can be unit-tested without a host.
enum OnboardingTemplateRecommender {
    /// Below this much memory, the Powerful template's ~5 GB model leaves too little headroom (the
    /// resident model plus OS would dominate an 8 GB machine), so it is disabled rather than offered
    /// as a trap. Chosen above 8 so stock 8 GB Macs are excluded while any 12 GB+ config is allowed.
    static let powerfulDisableBelowGigabytes = 10.0
    /// Between the disable floor and this ceiling, Powerful is allowed but flagged as potentially slow.
    static let powerfulWarnBelowGigabytes = 16.0
    /// Below this, the Everyday open-source path (~3 GB model) is flagged as potentially slow. Only
    /// relevant when Apple Intelligence is unavailable; the Apple Intelligence path has no such cost.
    static let everydayWarnBelowGigabytes = 8.0

    /// Resolves the engine, model, and behavior flags for a template given runtime facts.
    static func resolvePlan(
        for template: OnboardingTemplate,
        appleIntelligenceAvailable: Bool
    ) -> ResolvedTemplatePlan {
        let usesAppleIntelligence = template.prefersAppleIntelligence && appleIntelligenceAvailable
        let engine: SuggestionEngineKind = usesAppleIntelligence ? .appleIntelligence : .llamaOpenSource
        let model = usesAppleIntelligence
            ? nil
            : downloadableModel(filename: template.openSourceModelFilename)

        return ResolvedTemplatePlan(
            template: template,
            engine: engine,
            modelToDownload: model,
            wordCountPreset: template.wordCountPreset,
            enablesFastMode: template.enablesFastMode,
            enablesMultiLine: template.enablesMultiLine
        )
    }

    /// Whether a template should be recommended, disabled, or warned about on this Mac.
    static func availability(
        for template: OnboardingTemplate,
        hardware: HardwareCapability,
        appleIntelligenceAvailable: Bool
    ) -> OnboardingTemplateAvailability {
        let gigabytes = hardware.physicalMemoryGigabytes
        let recommended = recommendedTemplate(
            hardware: hardware,
            appleIntelligenceAvailable: appleIntelligenceAvailable
        )

        var isDisabled = false
        var warning: String?

        switch template {
        case .quick:
            break
        case .everyday:
            if !appleIntelligenceAvailable, gigabytes < everydayWarnBelowGigabytes {
                warning = "Uses a ~3 GB model, which may run slowly on this Mac."
            }
        case .powerful:
            if gigabytes < powerfulDisableBelowGigabytes {
                isDisabled = true
                warning = "Needs more memory than this Mac has (uses a ~5 GB model)."
            } else if gigabytes < powerfulWarnBelowGigabytes {
                warning = "Uses a ~5 GB model; may run slowly with less than 16 GB of memory."
            }
        }

        return OnboardingTemplateAvailability(
            template: template,
            isRecommended: template == recommended,
            isDisabled: isDisabled,
            warning: warning
        )
    }

    /// The single template to highlight as the safe default. Apple Intelligence makes Everyday the
    /// obvious choice; otherwise we keep low-memory Macs on Quick and everyone else on Everyday.
    /// Powerful is never the default — it is an opt-in for users who deliberately want the big model.
    static func recommendedTemplate(
        hardware: HardwareCapability,
        appleIntelligenceAvailable: Bool
    ) -> OnboardingTemplate {
        if appleIntelligenceAvailable {
            return .everyday
        }
        if hardware.physicalMemoryGigabytes < everydayWarnBelowGigabytes {
            return .quick
        }
        return .everyday
    }

    private static func downloadableModel(filename: String) -> DownloadableRuntimeModel? {
        RuntimeModelCatalog.downloadableModels.first { $0.filename == filename }
    }
}
