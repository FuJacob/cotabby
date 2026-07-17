import Foundation

/// File overview:
/// Pure rules that turn an `OnboardingTemplate` into a concrete plan and decide which templates to
/// recommend, warn about, or disable on a given Mac. All functions are deterministic over their
/// inputs (`HardwareCapability`, Apple Intelligence availability) so the onboarding UI can stay a
/// thin renderer and the decisions can be unit-tested without a host.
enum OnboardingTemplateRecommender {
    /// Below this much memory, the Powerful tier's model leaves too little headroom and is disabled
    /// rather than offered as a trap. The base-model tiers are far smaller than the old ~5 GB models,
    /// so the floor is 8: only sub-8 GB Macs (effectively pre-Apple-Silicon) are excluded, while every
    /// 8 GB+ machine may run it. Sizes for the copy are read from the catalog, not hardcoded here.
    static let powerfulDisableBelowGigabytes = 8.0
    /// Between the disable floor and this ceiling, Powerful is allowed but flagged as potentially slow
    /// under memory pressure from other apps. 16 GB and up is treated as comfortable.
    static let powerfulWarnBelowGigabytes = 16.0
    /// Below this, the Everyday open-source tier is flagged as potentially slow, and it is also the
    /// cutoff below which Quick becomes the recommended default. Only relevant when Apple Intelligence
    /// is unavailable; the Apple Intelligence path has no per-tier memory cost.
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
            enablesMultiLine: template.enablesMultiLine,
            enablesClipboardContext: template.enablesClipboardContext
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
            case .everyday, .custom:
                if gigabytes < everydayWarnBelowGigabytes {
                    warning = "Uses a \(modelSizeLabel(for: template)) model, which may run slowly on this Mac."
                }
            case .powerful:
                if gigabytes < powerfulDisableBelowGigabytes {
                    isDisabled = true
                    warning = "Needs more memory than this Mac has (uses a \(modelSizeLabel(for: template)) model)."
                } else if gigabytes < powerfulWarnBelowGigabytes {
                    warning = "Uses a \(modelSizeLabel(for: template)) model; may run slowly with less than 16 GB of memory."
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

    /// Human-readable size of the GGUF a template installs, read from the catalog so warning copy stays
    /// in sync with the actual model instead of a hardcoded number. Falls back to a generic phrase if
    /// the filename is missing from the catalog.
    private static func modelSizeLabel(for template: OnboardingTemplate) -> String {
        downloadableModel(filename: template.openSourceModelFilename)?.approximateSizeLabel ?? "local"
    }
}
