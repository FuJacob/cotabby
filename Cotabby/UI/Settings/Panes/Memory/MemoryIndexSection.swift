import SwiftUI

/// File overview:
/// The Memory pane's index and privacy settings: the index's state (passages, what is waiting,
/// what background indexing is doing, and the statistics in `MemoryIndexStatsView`), how memory is searched, and what memory keeps (retention and
/// exclusions) with Delete All.
///
/// Search settings take effect immediately; passage size changes re-embed every message, so those
/// are edited on a draft and applied together. Presentation only: changes go through
/// `MemoryControlModel`, status comes from `MemoryEngineController`.
struct MemoryIndexSection: View {
    @ObservedObject var control: MemoryControlModel
    @ObservedObject var controller: MemoryEngineController
    @State private var draft: MemoryIndexSettings?
    @State private var privacyDraft: MemoryPrivacySettings?
    @State private var confirmingDeleteAll = false
    @State private var confirmingRebuild = false

    var body: some View {
        if let saved = control.configuration?.index {
            // Clamped on every edit: shrinking the passage size takes the overlap down with it.
            let binding = Binding(get: { draft ?? saved }, set: { draft = $0.clamped() })
            Section {
                indexStatus
                Stepper("Results per suggestion: \(binding.wrappedValue.topK)", value: binding.topK, in: 1...20)
                VStack(alignment: .leading) {
                    Text("Meaning vs. exact words: \(Int((binding.wrappedValue.vectorWeight * 100).rounded()))% meaning")
                    Slider(value: binding.vectorWeight, in: 0...1, step: 0.05)
                    Text("Meaning finds a message however it was worded; exact words find names, numbers and codes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper("Passage size: \(binding.wrappedValue.chunkSize) words", value: binding.chunkSize, in: 64...400, step: 32)
                Stepper("Passage overlap: \(binding.wrappedValue.chunkOverlap) words", value: binding.chunkOverlap,
                        in: 0...(binding.wrappedValue.chunkSize / 2), step: 8)
                if let draft, draft.chunkSize != saved.chunkSize || draft.chunkOverlap != saved.chunkOverlap {
                    Text("Changing passages embeds every message again in the background.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Revert") { draft = nil }
                        .disabled(draft == nil || draft == saved)
                    Button("Apply") {
                        if let draft { control.updateIndexSettings(draft) }
                        draft = nil
                    }
                    .disabled(draft == nil || draft == saved)
                    .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Index")
            }
            .settingsItem(.memoryIndex)
        }

        if let savedPrivacy = control.configuration?.privacy {
            let privacy = Binding(get: { privacyDraft ?? savedPrivacy }, set: { privacyDraft = $0 })
            Section("Privacy") {
                Stepper(
                    privacy.wrappedValue.retentionDays == 0
                        ? "Keep messages: forever" : "Keep messages: last \(privacy.wrappedValue.retentionDays) days",
                    value: privacy.retentionDays, in: 0...3650, step: 30
                )
                listField("Never remember conversations (one id per line; add one from the Playground)",
                          privacy.excludedConversations)
                listField("Never remember people (names or addresses, one per line)", privacy.excludedParticipants)
                HStack {
                    Button("Delete All Memory…", role: .destructive) { confirmingDeleteAll = true }
                    Spacer()
                    Button("Apply") {
                        if let privacyDraft { control.updatePrivacy(privacyDraft) }
                        privacyDraft = nil
                    }
                    .disabled(privacyDraft == nil || privacyDraft == savedPrivacy)
                }
                Text("Memory stays on this Mac, encrypted in Cotabby's folder. It is never sent to an endpoint model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsItem(.memoryPrivacy)
            .confirmationDialog("Delete all memory?", isPresented: $confirmingDeleteAll) {
                Button("Delete All Memory", role: .destructive) { control.deleteAllMemory() }
            } message: {
                Text("Removes every stored message and its index. Sources stay configured and can sync again.")
            }
        }
    }

    private var indexStatus: some View {
        let status = controller.status
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(status.passages) passages searchable · \(MemoryPaneView.byteLabel(status.vectorBytes)) in memory")
                    Text(activityLine(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-index…") { confirmingRebuild = true }
                    .controlSize(.small)
            }
            if status.isIndexing, status.pendingMessages > 0 {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            MemoryIndexStatsView(status: status, sources: control.sources)
                .padding(.top, 4)
        }
        .confirmationDialog("Embed every message again?", isPresented: $confirmingRebuild) {
            Button("Re-index") { control.rebuildIndex() }
        } message: {
            Text("Searches keep working with what is already embedded while it runs, in the background while the Mac is plugged in.")
        }
    }

    private func activityLine(_ status: MemoryEngineStatus) -> String {
        var parts: [String] = [status.activity.isEmpty ? "Starting…" : status.activity]
        if status.isIndexing, let rate = status.passagesPerSecond, rate > 0 {
            parts.append(String(format: "%.0f passages/s", rate))
        }
        return parts.joined(separator: " · ")
    }

    private func listField(_ title: String, _ values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { values.wrappedValue.joined(separator: "\n") },
                set: {
                    values.wrappedValue = $0.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            ))
            .font(.callout)
            .frame(minHeight: 44, maxHeight: 90)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
        }
    }
}
