import AppKit
import SwiftUI

/// File overview:
/// The Memory pane's playground: pick one of your real conversations, type what you might write
/// there, and see exactly what memory would hand a suggestion (and how widely it had to look).
///
/// Conversations are picked from the engine's list of recently active ones rather than typed, so
/// there is nothing to spell exactly, and the search names the conversation by id (the scope a
/// suggestion gets after the app's window title is matched). "All of memory" is for exploring and
/// is never used by suggestions.
struct MemoryPlaygroundSection: View {
    @ObservedObject var control: MemoryControlModel
    @State private var query = ""
    @State private var sourceID = ""
    @State private var conversationKey = ""
    @State private var filter = ""
    @State private var global = false

    private var searchableSources: [MemorySource] {
        control.sources.filter { $0.enabled && $0.stats.messages > 0 }
    }

    private var filteredConversations: [MemoryConversation] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return control.playgroundConversations }
        return control.playgroundConversations.filter { $0.title.lowercased().contains(needle) }
    }

    private var selectedConversation: MemoryConversation? {
        control.playgroundConversations.first { Self.key($0) == conversationKey }
    }

    var body: some View {
        Section {
            Toggle("Search all of memory (exploring only; suggestions never do this)", isOn: $global)
            if !global {
                if searchableSources.isEmpty {
                    Text("Turn on a source and let it sync to try memory here.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Source", selection: $sourceID) {
                        ForEach(searchableSources) { Text($0.title).tag($0.id) }
                    }
                    TextField("Filter conversations", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Picker("Conversation", selection: $conversationKey) {
                        Text("Choose a conversation").tag("")
                        ForEach(filteredConversations.prefix(200), id: \.self) { conversation in
                            Text(Self.label(conversation)).tag(Self.key(conversation))
                        }
                    }
                    if let conversation = selectedConversation {
                        Button("Never Remember This Conversation") {
                            control.neverRemember(conversation)
                            conversationKey = ""
                        }
                        .controlSize(.small)
                        .help("Forgets it and skips it in later syncs (Privacy lists it).")
                    }
                }
            }
            TextField("What you might write…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)
            HStack {
                Spacer()
                if control.isSearching { ProgressView().controlSize(.small) }
                Button("Search", action: runSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || (!global && selectedConversation == nil))
            }
            if let result = control.playgroundResult {
                Text(Self.summary(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(result.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.byline(hit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(hit.text)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Playground")
        }
        .settingsItem(.memoryPlayground)
        .onAppear(perform: chooseDefaultSource)
        .onChange(of: control.sources) { _, _ in chooseDefaultSource() }
        .onChange(of: sourceID) { _, source in
            conversationKey = ""
            if !source.isEmpty { control.loadConversations(source: source) }
        }

    }

    /// Picks the first source that has messages once the source list has loaded (the list arrives
    /// after the pane appears, which left the picker empty and every search "not found").
    private func chooseDefaultSource() {
        guard !searchableSources.contains(where: { $0.id == sourceID }) else { return }
        sourceID = searchableSources.first?.id ?? ""
    }

    private func runSearch() {
        if global {
            control.searchEverything(query: query, sources: searchableSources.map(\.id))
        } else if let conversation = selectedConversation {
            control.search(query: query, conversation: conversation)
        }
    }

    static func key(_ conversation: MemoryConversation) -> String {
        "\(conversation.source)|\(conversation.conversationId)"
    }

    static func label(_ conversation: MemoryConversation) -> String {
        let date = Date(timeIntervalSince1970: conversation.lastTimestamp).formatted(date: .abbreviated, time: .omitted)
        let title = conversation.title.isEmpty ? "(untitled)" : conversation.title
        return "\(title) · \(date)"
    }

    static func summary(_ result: MemorySearchResult) -> String {
        let scope: String
        switch result.scope {
        case "conversation": scope = "from this conversation"
        case "person": scope = "from this conversation and others with exactly the same people"
        case "global": scope = "from all of memory"
        case "answer": scope = "from your answer sources"
        default: scope = "conversation not found, so nothing (suggestions never fall back to other chats)"
        }
        return "\(result.hits.count) result\(result.hits.count == 1 ? "" : "s") \(scope) in \(Int(result.elapsedMs.rounded())) ms"
    }

    static func byline(_ hit: MemorySearchResult.Hit) -> String {
        let date = Date(timeIntervalSince1970: hit.timestamp).formatted(date: .abbreviated, time: .shortened)
        let speaker = hit.isFromMe ? "You" : hit.sender
        return "\(speaker) · \(hit.conversationTitle) · \(date) · \(hit.via)"
    }
}
