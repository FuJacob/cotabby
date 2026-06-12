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
            Image("CotabbyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Cotabby")
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
        // Stack the support copy and the call-to-action vertically so the button sits below the
        // paragraphs instead of competing with them on the right edge of the row. `LabeledContent`
        // placed the value column next to the label, which made the wall of text visually compete
        // with a small button — the natural reading order is paragraphs first, then action.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Cotabby started from a simple belief: AI should run on your device, "
                    + "respect your privacy, and remain open to everyone."
                )

                Text(
                    "We're building Cotabby in our spare time, one release at a time. "
                    + "If Cotabby has helped you, your support helps us keep improving it."
                )
            }
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

    /// One row per resource (rather than one stacked row) so each link is a separate form row that
    /// search can scroll to and pulse individually.
    @ViewBuilder
    private var resourceRows: some View {
        if let repoURL = URL(string: "https://github.com/FuJacob/Cotabby") {
            Link(destination: repoURL) {
                Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .settingsItem(.githubRepository)
        }
        if let wikiURL = URL(string: "https://github.com/FuJacob/Cotabby/wiki") {
            Link(destination: wikiURL) {
                Label("Wiki & Contributor Guide", systemImage: "book")
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
        Text(
            "Remove Cotabby from Applications. To fully clean up app data, "
            + "delete ~/Library/Application Support/Cotabby."
        )
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
