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

    /// Resolves the model and behavior flags for a template under an explicitly chosen engine.
    ///
    /// The engine is now picked by the user at the top of the onboarding step rather than inferred
    /// from the tier, so a tier only contributes its behavior flags. Apple Intelligence downloads
    /// nothing; Open Source maps each tier to its local GGUF.
    static func resolvePlan(
        for template: OnboardingTemplate,
        engine: SuggestionEngineKind
    ) -> ResolvedTemplatePlan {
        let model: DownloadableRuntimeModel? =
            engine == .appleIntelligence
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

    /// Whether a template should be recommended, disabled, or warned about under the chosen engine.
    ///
    /// Apple Intelligence has no per-tier download, so every tier is available there. The hardware
    /// disable/warn rules only apply to the Open Source engine, where each tier is a local model of
    /// a specific size.
    static func availability(
        for template: OnboardingTemplate,
        hardware: HardwareCapability,
        engine: SuggestionEngineKind
    ) -> OnboardingTemplateAvailability {
        let gigabytes = hardware.physicalMemoryGigabytes
        let recommended = recommendedTemplate(hardware: hardware, engine: engine)

        var isDisabled = false
        var warning: String?

        if engine == .llamaOpenSource {
            switch template {
            case .quick:
                break
            case .everyday:
                if gigabytes < everydayWarnBelowGigabytes {
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
        }

        return OnboardingTemplateAvailability(
            template: template,
            isRecommended: template == recommended,
            isDisabled: isDisabled,
            warning: warning
        )
    }

    /// The single tier to highlight as the safe default under the chosen engine. Apple Intelligence
    /// has no size cost, so Everyday is the obvious balance; on Open Source we keep low-memory Macs
    /// on Quick and everyone else on Everyday. Powerful is never the default — it is an opt-in for
    /// users who deliberately want the big model.
    static func recommendedTemplate(
        hardware: HardwareCapability,
        engine: SuggestionEngineKind
    ) -> OnboardingTemplate {
        if engine == .appleIntelligence {
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
