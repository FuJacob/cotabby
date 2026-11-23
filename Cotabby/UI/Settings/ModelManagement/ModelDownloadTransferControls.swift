import SwiftUI

/// The trailing control of a model download row: Get, the transfer controls, an installed
/// checkmark, or Retry. The recommended catalog and the Hugging Face browser both render it from
/// `ModelDownloadState`, so a model reads the same wherever it is listed.
struct ModelDownloadActionButton: View {
    let state: ModelDownloadState
    /// True when the file is already on disk whatever the download state says. An active
    /// transfer still wins, so a re-download in progress keeps its controls.
    var isInstalled = false
    let onDownload: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if isInstalled && !state.isDownloading && !state.isPaused {
            installedCheckmark
        } else {
            switch state {
            case .idle:
                Button("Get") { onDownload() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .downloading, .paused:
                ModelDownloadTransferControls(
                    state: state,
                    onResume: onDownload,
                    onPause: onPause,
                    onCancel: onCancel
                )
            case .downloaded:
                installedCheckmark
            case .failed:
                // The refresh symbol pairs with the row's failure text to read as "try again"
                // rather than a generic action.
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

    private var installedCheckmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.system(size: 16))
    }
}

/// Shared pause, resume, cancel, and progress presentation for an active model download.
struct ModelDownloadTransferControls: View {
    let state: ModelDownloadState
    let onResume: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch state {
        case .downloading(let progress, _, _):
            HStack(spacing: 6) {
                downloadIndicator(progress: progress)
                actionButton(
                    systemName: "pause.circle.fill",
                    color: .secondary,
                    label: "Pause download",
                    action: onPause
                )
                cancelButton
            }
        case .paused(let progress):
            HStack(spacing: 6) {
                if let progress {
                    percentageLabel(progress, color: .secondary)
                }
                actionButton(
                    systemName: "play.circle.fill",
                    color: .blue,
                    label: "Resume download",
                    action: onResume
                )
                cancelButton
            }
        case .idle, .downloaded, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func downloadIndicator(progress: Double?) -> some View {
        if let progress {
            percentageLabel(progress, color: .blue)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: 40)
        }
    }

    private func percentageLabel(_ progress: Double, color: Color) -> some View {
        Text("\(Int((progress * 100).rounded()))%")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 40, alignment: .trailing)
    }

    private var cancelButton: some View {
        actionButton(
            systemName: "xmark.circle.fill",
            color: .secondary,
            label: "Cancel download",
            action: onCancel
        )
    }

    private func actionButton(
        systemName: String,
        color: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct ModelDownloadProgressBar: View {
    let state: ModelDownloadState

    var body: some View {
        if let progress = state.progressFraction {
            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(state.isPaused ? .secondary : .blue)
        } else if state.isPaused {
            // A determinate empty bar communicates a stable pause instead of ongoing activity.
            ProgressView(value: 0, total: 1)
                .progressViewStyle(.linear)
                .tint(.secondary)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.blue)
        }
    }
}
