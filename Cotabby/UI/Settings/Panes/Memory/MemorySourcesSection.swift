import AppKit
import SwiftUI

/// File overview:
/// The Memory pane's sources: which message sources feed memory, whether each is ready
/// (permission, folder), how much it holds, and whether answers to questions may use it.
///
/// Presentation only: every change goes through `MemoryControlModel`. Requirements are rendered
/// from each source's declared requirements (`MemorySourceCatalog`).
struct MemorySourcesSection: View {
    @ObservedObject var control: MemoryControlModel
    @ObservedObject var historySync: MemoryHistorySync

    var body: some View {
        Section {
            ForEach(control.sources) { source in
                sourceRow(source)
            }
            if control.sources.isEmpty {
                Text("Loading sources…").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Sources")
                Spacer()
                Button("Sync All") { Task { await control.sync() } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .settingsItem(.memorySources)
    }

    // MARK: - Source

    private func sourceRow(_ source: MemorySource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { control.setSourceEnabled(source.id, enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(source.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                let check = Self.check(for: source, historySync: historySync)
                Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(check.ok ? .green : .orange)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if historySync.syncing.contains(source.id) {
                    ProgressView().controlSize(.small)
                }
            }

            ForEach(source.requirements, id: \.kind) { requirement in
                requirementControl(requirement, source: source)
            }

            // Calendar never answers from its events; availability answers read busy/free live.
            if source.enabled, MemorySourceCatalog.canAnswer(source.id) {
                Toggle(isOn: Binding(
                    get: { source.isAnswerSource },
                    set: { control.setAnswerSource(source.id, enabled: $0) }
                )) {
                    Text("Use for answers to questions (other conversations too)")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("Off by default. When on, answers can quote facts from any conversation of this source, " +
                      "shown with where they came from before you insert them.")
            }

            if source.stats.messages > 0 || source.enabled {
                HStack {
                    Text(Self.statsLabel(source.stats))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { Task { await control.sync(source.id) } }
                        .disabled(!source.enabled || !Self.check(for: source, historySync: historySync).ok
                                  || historySync.syncing.contains(source.id))
                    Button("Forget") { control.forget(source.id) }
                        .disabled(source.stats.messages == 0)
                        .help("Delete everything remembered from this source.")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func requirementControl(_ requirement: MemorySource.Requirement, source: MemorySource) -> some View {
        switch requirement.kind {
        case "folder":
            HStack {
                Text(source.options["folder"]?.nonEmptyPath ?? "No folder chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder(for: source.id) }
                    .controlSize(.small)
            }
        case "full_disk_access":
            if historySync.readiness[source.id] == .needsFullDiskAccess {
                Button("Open Full Disk Access Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .help("Add Cotabby to Full Disk Access so it can read \(source.title)'s local history.")
            }
        case "calendar":
            if historySync.readiness[source.id]?.isReady == false {
                Button("Allow Calendar Access") { allowCalendarAccess() }
                    .controlSize(.small)
                    .help("Let Cotabby read your calendars. macOS asks once; after that, use System Settings.")
            }
        default:
            if !requirement.detail.isEmpty {
                Text("\(requirement.title): \(requirement.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Asks macOS for Calendar access the first time; after a refusal only System Settings can grant
    /// it, so the button opens that pane instead. Readiness is re-checked either way.
    private func allowCalendarAccess() {
        guard EventKitCalendar.canAsk else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task {
            _ = await EventKitCalendar.requestAccess()
            historySync.refreshReadiness()
        }
    }

    private func chooseFolder(for sourceID: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        control.setSourceOption(sourceID, key: "folder", value: url.path)
    }

    /// What to show as a source's readiness: whether macOS lets Cotabby read it, and how the last
    /// sync went.
    static func check(for source: MemorySource, historySync: MemoryHistorySync) -> (ok: Bool, message: String) {
        if source.id == DocumentsHistoryReader.id, (source.options["folder"] ?? "").isEmpty {
            return (false, "Choose a folder for this source.")
        }
        guard let readiness = historySync.readiness[source.id] else { return (true, "Checking access…") }
        if readiness.isReady, let outcome = historySync.lastOutcome[source.id] {
            return (true, "Ready · \(outcome)")
        }
        return (readiness.isReady, readiness.message)
    }

    static func statsLabel(_ stats: MemorySource.Stats) -> String {
        var parts = ["\(stats.messages) messages in \(stats.conversations) conversations"]
        if stats.pending > 0 { parts.append("\(stats.pending) waiting to be indexed") }
        if let last = stats.lastSync {
            let synced = RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date())
            parts.append("synced " + synced)
        }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    /// The path with the home folder shortened to `~`, or nil when empty.
    var nonEmptyPath: String? {
        guard !isEmpty else { return nil }
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
