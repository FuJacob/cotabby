import SwiftUI

/// File overview:
/// A dedicated step in the onboarding flow to collect the user's name and common tags.
struct WelcomeProfileStepView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Tell tabby about yourself")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("This helps tabby personalize your autocomplete suggestions.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                // Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 13, weight: .medium))

                    TextField("What should tabby call you?", text: Binding(
                        get: { suggestionSettings.userName },
                        set: { suggestionSettings.setUserName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                }

                // TODO: Re-enable "Things you type often" once we validate the feature's value.
                // VStack(alignment: .leading, spacing: 6) {
                //     Text("Things you type often")
                //         .font(.system(size: 13, weight: .medium))
                //
                //     Text("Optional. Tabby will self-learn, but feel free to add common phrases, email sign-offs, or jargon.")
                //         .font(.system(size: 11))
                //         .foregroundStyle(.secondary)
                //
                //     TagsInputView(
                //         tags: Binding(
                //             get: { suggestionSettings.userTags },
                //             set: { suggestionSettings.setUserTags($0) }
                //         ),
                //         placeholder: "e.g., 'Best regards, Jacob', 'PR approved', 'LGTM'"
                //     )
                // }
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
