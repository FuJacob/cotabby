import SwiftUI

/// Searchable HuggingFace GGUF model browser embedded in the Settings "Local Models" section.
/// Users search for repos, drill into one to see available GGUF quantizations, and download
/// directly into Tabby's model directory via the existing ModelDownloadManager.
struct HuggingFaceModelBrowserView: View {
    @ObservedObject var searchService: HuggingFaceSearchService
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    let onRefreshModels: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Browse HuggingFace", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                searchBar
                searchResultsContent
            }
            .padding(.top, 4)
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                searchService.reset()
            }
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search GGUF models…", text: $searchService.searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { searchService.search() }

            Button("Search") { searchService.search() }
                .disabled(searchService.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        switch searchService.searchState {
        case .idle:
            EmptyView()

        case .searching:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .noResults:
            Text("No GGUF models found.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)

        case .results(let models):
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 0) {
                    HFSearchResultRow(
                        model: model,
                        isSelected: isRepoSelected(model.id),
                        onSelect: {
                            if isRepoSelected(model.id) {
                                searchService.collapseDetail()
                            } else {
                                searchService.fetchFiles(for: model.id)
                            }
                        }
                    )
                    inlineDetailContent(for: model.id)
                }
            }

            if searchService.hasMoreResults {
                Button {
                    searchService.loadMore()
                } label: {
                    if searchService.isLoadingMore {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                                .font(.caption)
                        }
                    } else {
                        Text("Load More")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(searchService.isLoadingMore)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func inlineDetailContent(for repoId: String) -> some View {
        if isRepoSelected(repoId) {
            switch searchService.detailState {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading files…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .padding(.top, 4)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 16)
                    .padding(.top, 4)

            case .loaded(let loadedRepoId, let ggufFiles) where loadedRepoId == repoId:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ggufFiles) { file in
                        if let model = searchService.makeDownloadableModel(from: file, repoId: repoId) {
                            HFFileRow(
                                file: file,
                                repoId: repoId,
                                state: modelDownloadManager.state(for: model),
                                isInstalled: modelDownloadManager.isModelInstalled(filename: model.filename),
                                onDownload: {
                                    modelDownloadManager.download(model)
                                },
                                onCancel: {
                                    modelDownloadManager.cancel(filename: model.filename)
                                }
                            )
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 4)

            default:
                EmptyView()
            }
        }
    }

    private func isRepoSelected(_ repoId: String) -> Bool {
        searchService.selectedRepoId == repoId
    }
}

private struct HFSearchResultRow: View {
    let model: HFModelSearchResult
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.id)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Label(formattedDownloads, systemImage: "arrow.down.circle")
                        Label("\(model.likes)", systemImage: "heart")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var formattedDownloads: String {
        if model.downloads >= 1_000_000 {
            return String(format: "%.1fM", Double(model.downloads) / 1_000_000)
        } else if model.downloads >= 1_000 {
            return String(format: "%.1fK", Double(model.downloads) / 1_000)
        }
        return "\(model.downloads)"
    }
}

private struct HFFileRow: View {
    let file: HFRepoFile
    let repoId: String
    let state: ModelDownloadState
    let isInstalled: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Text(file.sizeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                actionButton
            }

            if state.isDownloading, let progress = state.progressFraction {
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            } else if state.isDownloading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.3))
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInstalled && !state.isDownloading {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        } else {
            switch state {
            case .idle:
                Button("Get") { onDownload() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

            case .downloading(let progress):
                HStack(spacing: 6) {
                    if let progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 40, alignment: .trailing)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 40)
                    }
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }

            case .downloaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 16))

            case .failed:
                Button {
                    onDownload()
                } label: {
                    Label("Retry", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
