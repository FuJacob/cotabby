import SwiftUI

/// File overview:
/// A dedicated step in the onboarding flow to collect the user's name.
struct WelcomeProfileStepView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Tell Cotabby about yourself")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("This helps Cotabby personalize your autocomplete suggestions.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                // Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 13, weight: .medium))

                    TextField("What should Cotabby call you?", text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                }

                CustomRulesEditor(suggestionSettings: suggestionSettings)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Spacer(minLength: 0)

            WelcomeNavigation(
                canGoBack: true,
                canContinue: true,
                onBack: onBack,
                onContinue: onContinue
            )
        }
    }
}
