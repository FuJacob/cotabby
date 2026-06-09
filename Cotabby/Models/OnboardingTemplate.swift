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

/// One of the onboarding starting points. Quick, Everyday, and Powerful are the curated tiers shown
/// as selectable cards (`curatedTiers`). Custom is the neutral "set it up yourself" option that
/// applies lean defaults; it is no longer its own card. The template step's "Set up later" button
/// applies it under the hood so a user who does not want a curated tier can still move forward and
/// configure the rest in Settings.
enum OnboardingTemplate: String, CaseIterable, Identifiable, Equatable, Sendable {
    case quick
    case everyday
    case powerful
    case custom

    var id: String { rawValue }

    /// The curated tiers shown as selectable cards in onboarding, in display order. Excludes
    /// `.custom`, which is applied implicitly by the "Set up later" button rather than picked from a
    /// card. Kept distinct from `allCases` so the pure recommender still reasons over every tier.
    static let curatedTiers: [OnboardingTemplate] = [.quick, .everyday, .powerful]

    var title: String {
        switch self {
        case .quick:
            return "Quick"
        case .everyday:
            return "Everyday"
        case .powerful:
            return "Powerful"
        case .custom:
            return "Custom"
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
        case .custom:
            return "Keep your settings, or start from defaults"
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
        case .custom:
            return "Returning users keep every setting they've already tuned. "
                + "New users start from Cotabby's lean defaults and fine-tune length, model, and behavior in Settings."
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
        case .custom:
            return "slider.horizontal.3"
        }
    }

    var wordCountPreset: SuggestionWordCountPreset {
        switch self {
        case .quick:
            return .fourToSeven
        case .everyday:
            return .sevenToTwelve
        case .powerful:
            return .twelveToTwenty
        case .custom:
            return .sevenToTwelve
        }
    }

    /// Quick favors low latency by skipping screen-context extraction.
    var enablesFastMode: Bool {
        self == .quick
    }

    /// Multi-line is off in every tier so a fresh user does not get long block completions before
    /// they have chosen that tradeoff in General.
    var enablesMultiLine: Bool { false }

    /// Quick stays lean by skipping the per-keystroke clipboard read and the extra prompt bytes it
    /// adds; Everyday, Powerful, and Custom pay that small cost for the extra signal.
    var enablesClipboardContext: Bool {
        switch self {
        case .quick:
            return false
        case .everyday, .powerful, .custom:
            return true
        }
    }

    /// The local GGUF this template installs when the Open Source engine is selected. Custom uses the
    /// same balanced base model as Everyday so it works out of the box; the user can swap it later.
    var openSourceModelFilename: String {
        switch self {
        case .quick:
            return "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"
        case .everyday:
            return "gemma-4-E2B.i1-Q6_K.gguf"
        case .powerful:
            return "gemma-4-E4B.i1-Q4_K_M.gguf"
        case .custom:
            return "gemma-4-E2B.i1-Q6_K.gguf"
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
