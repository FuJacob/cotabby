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
            Section { aboutHeader }
            Section("Support") { supportRow }
            Section("Resources") { linksRow }
            Section("Uninstall") { uninstallText }
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

            Button("Check for Updates") {
                appUpdateManager.checkForUpdates()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var supportRow: some View {
        LabeledContent {
            if let supportURL = URL(string: "https://ko-fi.com/cotabby") {
                Link(destination: supportURL) {
                    Label("Support Cotabby", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        } label: {
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
        }
    }

    @ViewBuilder
    private var linksRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let repoURL = URL(string: "https://github.com/FuJacob/Cotabby") {
                Link(destination: repoURL) {
                    Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            if let wikiURL = URL(string: "https://github.com/FuJacob/Cotabby/wiki") {
                Link(destination: wikiURL) {
                    Label("Wiki & Contributor Guide", systemImage: "book")
                }
            }
            Button {
                isShowingAcknowledgements = true
            } label: {
                Label("Acknowledgements", systemImage: "doc.text")
            }
            .buttonStyle(.link)
        }
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
