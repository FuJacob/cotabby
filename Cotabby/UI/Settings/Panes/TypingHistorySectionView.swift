import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Typing History" section of the Context settings pane.
///
/// Presentation only: every action goes to `TypingHistoryStore`, which owns the preferences,
/// archive, and recording. A separate view keeps the Context pane readable and puts the privacy
/// wording for this feature in one place.
struct TypingHistorySectionView: View {
    @ObservedObject var store: TypingHistoryStore
    @State private var isConfirmingDeleteAll = false

    var body: some View {
        Section("Typing History") {
            Toggle(isOn: Binding(get: { store.preferences.isUsingHistory }, set: { store.setUsingHistory($0) })) {
                SettingsRowLabel(
                    title: "Use My Typing History",
                    description: "Finishes phrases you often type and shows the model examples of how you " +
                        "write. Only Apple Intelligence and the local model use it; it is never sent to an endpoint.",
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .settingsItem(.typingHistory)

            Toggle(isOn: Binding(get: { store.preferences.isRecording }, set: { store.setRecording($0) })) {
                SettingsRowLabel(
                    title: "Record What I Type",
                    description: "Saves the text of fields where Cotabby is active, encrypted on this Mac. " +
                        "Password fields and disabled apps are never recorded.",
                    systemImage: "record.circle"
                )
            }
            .disabled(store.status != .ready)

            if !store.preferences.excludedBundleIdentifiers.isEmpty {
                ForEach(store.preferences.excludedBundleIdentifiers, id: \.self) { identifier in
                    LabeledContent {
                        Button("Remove") { store.setExcluded(identifier, excluded: false) }
                    } label: {
                        Text("Not recorded: \(Self.displayName(for: identifier))")
                    }
                }
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Button("Exclude an App…") { chooseAppToExclude() }
                    Button("Import Cotypist Export…") { chooseExportToImport() }
                        .disabled(store.status != .ready || store.isImporting)
                    Button("Delete All…", role: .destructive) { isConfirmingDeleteAll = true }
                        .disabled(store.recordCount == 0 || store.isImporting)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entryCountLabel)
                    if let message = statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(store.status == .ready ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .confirmationDialog(
                "Delete all typing history?",
                isPresented: $isConfirmingDeleteAll
            ) {
                Button("Delete All \(store.recordCount) Entries", role: .destructive) { store.deleteAll() }
            } message: {
                Text("This removes every recorded and imported entry and its encryption key. It can't be undone.")
            }
        }
    }

    private var entryCountLabel: String {
        switch store.status {
        case .loading: return "Opening typing history…"
        case .ready, .unavailable: return store.recordCount == 1 ? "1 entry stored" : "\(store.recordCount) entries stored"
        }
    }

    private var statusMessage: String? {
        if case let .unavailable(message) = store.status { return message }
        if store.isImporting { return "Importing…" }
        return store.lastImportMessage
    }

    /// Asks for the `user_inputs.json` file from a decrypted Cotypist export.
    private func chooseExportToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Cotypist Export"
        panel.message = "Choose user_inputs.json from your Cotypist export."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.importCotypistExport(from: url) }
    }

    private func chooseAppToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Don't Record in an App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        store.setExcluded(identifier, excluded: true)
    }

    private static func displayName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
