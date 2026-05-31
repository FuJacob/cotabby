import Foundation

/// File overview:
/// Pure description of which behaviors each `OnboardingTemplate` turns on or off. The onboarding
/// template card uses this to render a collapsible "what's included" section so the user can see
/// exactly what they're opting into before tapping a card.
///
/// Keeping this list as a pure helper (instead of inlining it in the SwiftUI view) means the same
/// summary is unit-testable and stays in lock-step with the source-of-truth properties on
/// `OnboardingTemplate`. If a template gains a new behavior flag, the row order here is the only
/// place to extend — the UI walks whatever rows this returns.

enum OnboardingTemplateFeatureValue: Equatable, Sendable {
    /// Toggled on by the template. UI renders a positive affordance (e.g., a check).
    case enabled
    /// Explicitly off under the template. UI renders a neutral/negative affordance (e.g., a dash).
    case disabled
    /// A non-boolean setting that takes a value (e.g., suggestion length preset). UI shows the
    /// trailing text alongside the row title.
    case detail(String)
}

struct OnboardingTemplateFeatureRow: Equatable, Sendable, Identifiable {
    let title: String
    let value: OnboardingTemplateFeatureValue

    /// `title` is unique within a template's row list, so it doubles as the SwiftUI identity key.
    var id: String { title }
}

enum OnboardingTemplateFeatureList {
    /// Returns the ordered rows shown in the template card's disclosure section.
    /// Order matters: the most user-visible knob (suggestion length) comes first, then behavior
    /// flags. Adding a new row here automatically surfaces it in the UI.
    static func rows(for template: OnboardingTemplate) -> [OnboardingTemplateFeatureRow] {
        [
            OnboardingTemplateFeatureRow(
                title: "Suggestion length",
                value: .detail(template.wordCountPreset.displayLabel)
            ),
            OnboardingTemplateFeatureRow(
                title: "Fast mode (skip screen context)",
                value: template.enablesFastMode ? .enabled : .disabled
            ),
            OnboardingTemplateFeatureRow(
                title: "Clipboard context",
                value: template.enablesClipboardContext ? .enabled : .disabled
            )
        ]
    }
}
