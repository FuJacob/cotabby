import SwiftUI

/// File overview:
/// "Home" detail pane: the welcoming landing surface of the Settings window and the first sidebar
/// row. It introduces what Cotabby is, replays the same inline-autocomplete and inline-emoji demos
/// shown on the final onboarding screen (`OnboardingFeatureShowcase`), and surfaces the Support
/// Cotabby call to action. It is the default pane on a fresh install; returning users still land on
/// their last-viewed pane.
///
/// The feature demos are inert, self-playing animations that never touch the real suggestion
/// pipeline, so this pane is safe to keep open without side effects.
struct HomePaneView: View {
    var body: some View {
        SettingsPaneScaffold {
            Section { introHeader }
            Section("See it in action") { OnboardingFeatureShowcase() }
            Section("Support") { supportRow }
        }
    }

    @ViewBuilder
    private var introHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("CotabbyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Cotabby")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Local-first AI autocomplete for macOS")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                "Cotabby suggests the next few words as ghost text in any text field, system-wide. "
                + "Press Tab to accept, or keep typing to ignore. It also completes inline :emoji: "
                + "shortcuts. Everything runs on your device; nothing is sent to the cloud."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var supportRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Cotabby is free and open source, maintained by two students in our spare time. "
                + "If it's useful to you, supporting development helps us keep improving it."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let supportURL = URL(string: "https://ko-fi.com/cotabby") {
                Link(destination: supportURL) {
                    Label("Support Cotabby", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }
}
