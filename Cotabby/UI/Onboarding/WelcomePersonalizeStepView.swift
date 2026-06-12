import SwiftUI

/// File overview:
/// The onboarding personalization step. Merges what used to be two wizard screens (the "about you"
/// name-and-languages step and the gated "writing style" custom-rules step) into one, so the flow
/// stays four counted steps whether or not custom rules are user-facing
/// (`CustomRulesCatalog.isUserFacingEnabled`).
///
/// The editors are the real settings components (`LanguageTagsEditor`, `CustomRulesEditor`)
/// writing through `SuggestionSettingsModel`; this view only supplies onboarding's card framing.
struct WelcomePersonalizeStepView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        VStack(spacing: 24) {
            OnboardingStepHeader(
                systemImage: "person.crop.circle.fill",
                title: "Make it yours",
                subtitle: "Cotabby writes in your languages and can address you by name."
            )
            .onboardingReveal(0)

            VStack(spacing: 12) {
                personalizeCard(icon: "textformat", title: "Your name", index: 1) {
                    TextField("What should Cotabby call you? (Optional)", text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                }

                personalizeCard(icon: "globe", title: "Languages", index: 2) {
                    LanguageTagsEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                }

                if CustomRulesCatalog.isUserFacingEnabled {
                    personalizeCard(icon: "character.cursor.ibeam", title: "Writing style", index: 3) {
                        CustomRulesEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                    }
                }
            }
        }
    }

    private func personalizeCard(
        icon: String,
        title: String,
        index: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CotabbyBrand.accent)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
        .onboardingReveal(index)
    }
}
