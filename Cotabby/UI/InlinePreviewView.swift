import Combine
import SwiftUI

/// File overview:
/// The SwiftUI content hosted inside the floating macro inline-preview panel. It is a pure renderer
/// of `InlinePreviewViewModel`: the trigger state machine and controller own all behavior, while this
/// view only reflects the current result text and the accept-key hint. A click reports back through
/// `onTap` so the user can accept with the mouse.

/// Observable state the controller pushes into the panel.
@MainActor
final class InlinePreviewViewModel: ObservableObject {
    @Published var previewText: String = ""
    /// The accept-key label shown as a keycap; `nil` hides it.
    @Published var acceptKeyLabel: String?
}

struct InlinePreviewView: View {
    @ObservedObject var model: InlinePreviewViewModel
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(model.previewText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let label = model.acceptKeyLabel {
                InlinePreviewKeycap(label: label)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .fixedSize()
    }
}

/// Small keycap pill mirroring the user's configured word-accept shortcut.
private struct InlinePreviewKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .fixedSize()
    }
}
