import SwiftUI

/// File overview:
/// Shared local-model installation UI used by onboarding and Settings.
///
/// Why this file exists:
/// the downloadable model catalog is product behavior, not onboarding-only behavior. Extracting it
/// here keeps the row layout, progress bar behavior, retry affordance, and folder actions in one
/// place so day-one and day-two install flows cannot drift apart.
struct DownloadableModelCatalogView: View {
    @ObservedObject var modelDownloadManager: ModelDownloadManager

    let onRefreshModels: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Recommended Models")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(modelDownloadManager.models) { model in
                DownloadableModelRow(
                    model: model,
                    state: modelDownloadManager.state(for: model),
                    onDownload: { modelDownloadManager.download(model) },
                    onCancel: { modelDownloadManager.cancel(filename: model.filename) }
                )
            }

            HStack(spacing: 12) {
                Button {
                    modelDownloadManager.importModel()
                    onRefreshModels()
                } label: {
                    Label("Add Your Own", systemImage: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    onRefreshModels()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Import any .gguf model from your computer.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// App Store-style model row with inline progress state.
/// This view intentionally renders from `ModelDownloadState` only, so onboarding and Settings
/// reflect the same source of truth without special-case UI logic.
private struct DownloadableModelRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelDownloadState
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))

                    Text("(\(model.actualModelName))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(metadataText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                }

                Spacer(minLength: 0)

                modelActionButton
            }

            if state.isDownloading {
                downloadProgressBar
            }

            // Failure messages get their own wrapping row. Validation errors
            // include exact byte counts and partial checksum prefixes, which
            // would clip the size label or get truncated to one line if we
            // tried to fit them inline with the metadata.
            if case .failed(let message) = state {
                failureMessageRow(message: message)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.3))
        )
    }

    /// Renders the localized error from `.failed(message)` as wrapping red
    /// text below the row body. Pinned to `fixedSize(vertical:)` so SwiftUI
    /// allocates enough vertical space for the wrap rather than clipping.
    @ViewBuilder
    private func failureMessageRow(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var modelActionButton: some View {
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
                // Plain SF Symbol button keeps the row compact and matches
                // the "Get"/"Retry" button affordance scale. Cancel is the
                // affirmative action while downloading, so it gets the same
                // visual weight as Get does in the idle state.
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
            // Refresh symbol gives the button a visual cue that it's not just
            // any "tap to do something"; pairs with the warning row below to
            // reinforce "something went wrong, try again."
            Button {
                onDownload()
            } label: {
                Label("Retry", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var metadataText: String {
        let installationStatus: String
        switch state {
        case .idle:
            installationStatus = "Not installed"
        case .downloading:
            installationStatus = state.statusText
        case .downloaded:
            installationStatus = "Installed"
        case .failed:
            // Terse here; the full message lives in `failureMessageRow` below
            // where it has room to wrap. Mixing a multi-line error into the
            // size-label line would either truncate or push the size off
            // screen on smaller windows.
            installationStatus = "Download failed"
        }

        return "\(installationStatus)  •  \(model.approximateSizeLabel)"
    }

    private var statusColor: Color {
        switch state {
        case .downloaded: return .green
        case .downloading: return .blue
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    @ViewBuilder
    private var downloadProgressBar: some View {
        if let progress = state.progressFraction {
            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(.blue)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.blue)
        }
    }
}
