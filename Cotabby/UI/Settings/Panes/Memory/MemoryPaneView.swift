import AppKit
import SwiftUI

/// File overview:
/// Settings → Memory: everything about conversation memory, the encrypted, on-device index of the
/// user's chat and mail history that suggestions and answers draw on.
///
/// Presentation only. Memory's lifecycle (on/off, the embedding model, starting the engine) belongs
/// to `MemoryEngineController`; settings, sources and searches go through `MemoryControlModel`. The
/// pane is split into sections by responsibility so each file stays readable: this one holds the
/// switch, the model and the engine's state, the others hold sources, index and privacy, and the
/// playground.
struct MemoryPaneView: View {
    @ObservedObject var controller: MemoryEngineController
    @ObservedObject var control: MemoryControlModel
    @ObservedObject var downloads: ModelDownloadManager
    @State private var confirmingReset = false
    @State private var confirmingDelete = false

    init(controller: MemoryEngineController, control: MemoryControlModel) {
        self.controller = controller
        self.control = control
        downloads = controller.downloads
    }

    var body: some View {
        SettingsPaneScaffold {
            engineSection
            if controller.state == .running {
                MemorySourcesSection(control: control, historySync: control.historySync)
                MemoryAnswersSection(control: control)
                MemoryIndexSection(control: control, controller: controller)
                MemoryPlaygroundSection(control: control)
            }
        }
        .onAppear {
            control.beginObserving()
            control.historySync.checkFullDiskAccess()
            control.historySync.refreshReadiness()
        }
        // Coming back from System Settings makes Cotabby active again: re-check right away so a
        // fresh grant shows without restarting.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            control.historySync.checkFullDiskAccess()
        }
        .onDisappear { control.endObserving() }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Toggle(isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) })) {
                SettingsRowLabel(
                    title: "Conversation Memory",
                    description: "Remember your chat and mail history on this Mac, encrypted, so suggestions can use what " +
                        "was said earlier in the same conversation. Nothing leaves the Mac, and memory is never " +
                        "sent to an endpoint model.",
                    systemImage: "brain"
                )
            }
            .settingsItem(.memoryService)

            if controller.isEnabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("Status")
                    Spacer()
                    Text(stateLabel)
                        .foregroundStyle(stateIsProblem ? .orange : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                engineActions
                FullDiskAccessRow(historySync: control.historySync)
                if let error = control.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            // Deleting needs no running engine (no model): memory switched off, or unable to start,
            // still lets the user remove what it stored. While it runs, Delete All lives with the
            // privacy settings; after a key mismatch, the row above offers it.
            if controller.state != .running, controller.state != .keyMismatch, controller.hasStoredMemory {
                storedMemoryDeletion
            }
        } header: {
            Text("Memory")
        }
    }

    @ViewBuilder
    private var engineActions: some View {
        switch controller.state {
        case .needsModel:
            modelDownload
        case .failed:
            HStack {
                Button("Try Again") { controller.restart() }
                Button("Open Memory Folder") { NSWorkspace.shared.open(controller.paths.root) }
            }
        case .running:
            HStack {
                Button("Restart") { controller.restart() }
                Button("Open Memory Folder") { NSWorkspace.shared.open(controller.paths.root) }
            }
            .controlSize(.small)
        case .keyMismatch:
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory is encrypted with a key this Mac's Keychain no longer has, so it cannot be read. " +
                     "Delete it and sync your sources again to rebuild it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Memory and Start Over…", role: .destructive) { confirmingReset = true }
            }
            .confirmationDialog("Delete the unreadable memory?", isPresented: $confirmingReset) {
                Button("Delete Memory", role: .destructive) { controller.deleteMemoryData() }
            } message: {
                Text("Your sources and settings stay; only the stored messages are deleted.")
            }
        case .starting, .disabled:
            EmptyView()
        }
    }

    private var storedMemoryDeletion: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Stored messages stay on this Mac, encrypted, until you delete them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Delete Stored Memory…", role: .destructive) { confirmingDelete = true }
                .controlSize(.small)
        }
        .confirmationDialog("Delete everything memory stored?", isPresented: $confirmingDelete) {
            Button("Delete Stored Memory", role: .destructive) { controller.deleteMemoryData() }
        } message: {
            Text("Your sources and settings stay; the stored messages and their index are deleted.")
        }
    }

    /// The embedding model is downloaded once (about 640 MB) and runs inside Cotabby on this Mac.
    private var modelDownload: some View {
        let model = MemoryEngineController.embeddingModel
        let modelState = downloads.state(for: model)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Memory understands messages with a small embedding model that runs on this Mac " +
                 "(\(model.displayName), \(model.approximateSizeLabel), downloaded from Hugging Face once).")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch modelState {
            case .downloading(let progress, _, _):
                ProgressView(value: progress ?? 0)
                HStack {
                    Text(modelState.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { downloads.pause(model) }
                    Button("Cancel") { downloads.cancel(model) }
                }
                .controlSize(.small)
            case .paused:
                HStack {
                    Text(modelState.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { downloads.resume(model) }
                }
                .controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Download Again") { controller.downloadModel() }
            case .idle, .downloaded:
                Button("Download Model") { controller.downloadModel() }
            }
        }
    }

    private var stateLabel: String {
        switch controller.state {
        case .disabled: return "Off"
        case .needsModel: return "Needs its embedding model"
        case .starting: return "Starting…"
        case .running:
            let status = controller.status
            return status.isIndexing ? "Running · indexing in the background" : "Running"
        case .failed(let message): return message
        case .keyMismatch: return "Memory cannot be read with this Mac's key"
        }
    }

    private var stateIsProblem: Bool {
        switch controller.state {
        case .failed, .keyMismatch: return true
        default: return false
        }
    }

    static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
