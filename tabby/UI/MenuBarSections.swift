import AppKit
import SwiftUI

/// File overview:
/// Small, focused components used by the menu-bar panel.
/// These stay purely presentational — all state derivation lives in `MenuBarView`.

/// Colored pill that communicates Tabby's overall readiness at a glance.
/// Green = ready, orange = degraded/needs attention, red = broken, gray = transitional.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Compact labeled row for menu-bar pickers. Keeps label width consistent across
/// Engine / Model / Length rows without a heavy generic layout container.
struct MenuBarPickerRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A single permission row with a checkmark/x indicator and an inline "Grant" button.
///
/// The row measures the Grant button in screen coordinates so callers can anchor AppKit overlays
/// to the exact clicked control. That keeps the menu row presentational while still giving the
/// permission-guidance service the geometry it needs for its cross-window animation.
struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: (CGRect?) -> Void

    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(granted ? .green : .orange)

            Text(title)
                .font(.caption)

            Spacer(minLength: 0)

            if !granted {
                Button("Grant") {
                    action(actionButtonFrame.isEmpty ? nil : actionButtonFrame)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
    }
}
