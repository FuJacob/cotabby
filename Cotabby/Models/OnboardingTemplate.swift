import Foundation

/// File overview:
/// Value types for the onboarding "starting point" templates. A template is a curated bundle of
/// settings plus a recommended model, so a new user can pick one card instead of reasoning about
/// engines, model sizes, and completion length on their own.
///
/// The template only declares *intent* (which tier, which length, which behavior flags). The
/// concrete engine and downloadable model are resolved by `OnboardingTemplateRecommender` because
/// that decision depends on runtime facts (Apple Intelligence availability, installed RAM) that a
/// static value type should not capture. Keeping the data here and the rules in `Support/` keeps the
/// resolution pure and unit-testable.

/// One of the three onboarding starting points the user chooses from.
enum OnboardingTemplate: String, CaseIterable, Identifiable, Equatable, Sendable {
    case quick
    case everyday
    case powerful

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick:
            return "Quick"
        case .everyday:
            return "Everyday"
        case .powerful:
            return "Powerful"
        }
    }

    /// One-line summary shown under the title on the card.
    var tagline: String {
        switch self {
        case .quick:
            return "Fast and lightweight"
        case .everyday:
            return "Balanced for daily writing"
        case .powerful:
            return "Highest quality"
        }
    }

    /// Longer supporting copy describing the trade-off the user is opting into. Kept engine-neutral
    /// because the engine (and any download size) is now chosen separately above the tier and shown
    /// in the per-tier footer; the tier itself only tunes speed/length.
    var detail: String {
        switch self {
        case .quick:
            return "Short, snappy completions that keep up with fast typing and stay light on resources."
        case .everyday:
            return "A balance of speed and quality for everyday writing."
        case .powerful:
            return "Longer suggestions and higher quality on harder prompts."
        }
    }

    var systemImageName: String {
        switch self {
        case .quick:
            return "hare.fill"
        case .everyday:
            return "sparkles"
        case .powerful:
            return "bolt.fill"
        }
    }

    var wordCountPreset: SuggestionWordCountPreset {
        switch self {
        case .quick:
            return .threeToSeven
        case .everyday:
            return .sevenToTwelve
        case .powerful:
            return .twelveToTwenty
        }
    }

    /// Quick favors low latency by skipping screen-context extraction.
    var enablesFastMode: Bool {
        self == .quick
    }

    /// Multi-line is off in every tier — the onboarding presets stay single-line so a fresh user
    /// doesn't get long block completions before they've chosen that tradeoff in General.
    var enablesMultiLine: Bool { false }

    /// Quick stays lean by skipping the per-keystroke clipboard read and the extra prompt bytes
    /// it adds; Everyday and Powerful pay that small cost for the extra signal.
    var enablesClipboardContext: Bool {
        self != .quick
    }

    /// The local GGUF this template installs when the Open Source engine is selected.
    var openSourceModelFilename: String {
        switch self {
        case .quick:
            return "SmolLM2-135M-Instruct-q8_0.gguf"
        case .everyday:
            return "gemma-4-E2B-it-Q4_K_M.gguf"
        case .powerful:
            return "gemma-4-E4B-it-Q4_K_M.gguf"
        }
    }
}

/// The concrete configuration a template resolves to once runtime facts are known.
/// `modelToDownload` is `nil` when the plan uses Apple Intelligence, since nothing is downloaded.
struct ResolvedTemplatePlan: Equatable, Sendable {
    let template: OnboardingTemplate
    let engine: SuggestionEngineKind
    let modelToDownload: DownloadableRuntimeModel?
    let wordCountPreset: SuggestionWordCountPreset
    let enablesFastMode: Bool
    let enablesMultiLine: Bool
    let enablesClipboardContext: Bool
}

/// Whether a template can be offered on the current Mac, plus optional advisory copy.
/// `isDisabled` means the machine cannot reasonably run the template's model at all; `warning` is a
/// softer "this will work but may be slow" note shown without blocking selection.
struct OnboardingTemplateAvailability: Equatable, Sendable {
    let template: OnboardingTemplate
    let isRecommended: Bool
    let isDisabled: Bool
    let warning: String?
}

/// A snapshot of the host's capability relevant to model selection.
struct HardwareCapability: Equatable, Sendable {
    let physicalMemoryBytes: UInt64
    let isAppleSilicon: Bool

    /// Binary gigabytes (GiB), matching how macOS reports installed memory.
    var physicalMemoryGigabytes: Double {
        Double(physicalMemoryBytes) / 1_073_741_824
    }
}
