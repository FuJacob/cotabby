import AppKit
import SwiftUI

/// File overview:
/// "About" detail pane of the redesigned Settings window. Consolidates what used to live across
/// three legacy sections (header, support CTA, uninstall) plus a new Acknowledgements modal that
/// lists the third-party packages Cotabby ships with.
struct AboutPaneView: View {
    let appUpdateManager: AppUpdateManager

    @State private var isShowingAcknowledgements = false

    var body: some View {
        SettingsPaneScaffold {
            Section { aboutHeader.settingsItem(.checkForUpdates) }
            Section("Support") { supportRow.settingsItem(.support) }
            Section("Resources") { resourceRows }
            Section("Uninstall") { uninstallText.settingsItem(.uninstall) }
        }
        .sheet(isPresented: $isShowingAcknowledgements) {
            AcknowledgementsView { isShowingAcknowledgements = false }
        }
    }

    @ViewBuilder
    private var aboutHeader: some View {
        HStack(spacing: 12) {
            Image("CoHamsterLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CoHamster")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))

                Text("Local macOS AI Autocomplete")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(appVersionText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                appUpdateManager.checkForUpdates()
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var supportRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Help improve CoHamster by reporting bugs, suggesting features, or contributing code.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "https://github.com/mc-hamster/CoHamster/issues") {
                Link("Contribute & Report Issues", destination: url)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// One row per resource (rather than one stacked row) so each link is a separate form row that
    /// search can scroll to and pulse individually.
    @ViewBuilder
    private var resourceRows: some View {
        let repository = "https://github.com/mc-hamster/CoHamster"
        if let repoURL = URL(string: repository) {
            Link(destination: repoURL) {
                Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .settingsItem(.githubRepository)
        }
        if let wikiURL = URL(string: "https://github.com/mc-hamster/CoHamster/blob/master/CONTRIBUTING.md") {
            Link(destination: wikiURL) {
                Label("Contributor Guide", systemImage: "book")
            }
            .settingsItem(.wiki)
        }
        Button {
            isShowingAcknowledgements = true
        } label: {
            Label("Acknowledgements", systemImage: "doc.text")
        }
        .buttonStyle(.link)
        .settingsItem(.acknowledgements)
    }

    @ViewBuilder
    private var uninstallText: some View {
        let dataDirectory = BundledRuntimeLocator.userRuntimeDirectoryURL().deletingLastPathComponent().path
        Text("Remove CoHamster from Applications. To fully clean up model data, delete \(dataDirectory).")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The app bundle is the canonical source for human-facing version text.
    private var appVersionText: String {
        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case (let shortVersion?, let buildNumber?) where shortVersion != buildNumber:
            return "Version \(shortVersion) (\(buildNumber))"
        case (let shortVersion?, _):
            return "Version \(shortVersion)"
        case (_, let buildNumber?):
            return "Build \(buildNumber)"
        default:
            return "Unknown version"
        }
    }
}
