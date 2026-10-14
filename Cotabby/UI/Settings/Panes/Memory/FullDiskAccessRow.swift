import AppKit
import SwiftUI

/// The Memory pane's Full Disk Access row: whether Cotabby has it, why memory needs it, and the
/// shortest way to grant it.
///
/// macOS has no request API for Full Disk Access; the user adds the app in System Settings →
/// Privacy & Security → Full Disk Access. So the row opens that list, reveals this copy of Cotabby in
/// Finder (it can be dragged into the list), and re-checks on demand. The status itself comes from
/// `MemoryHistorySync.checkFullDiskAccess`, which the pane also re-runs whenever Cotabby becomes
/// active again.
struct FullDiskAccessRow: View {
    @ObservedObject var historySync: MemoryHistorySync

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Full Disk Access", systemImage: "externaldrive.badge.checkmark")
                Spacer()
                statusLabel
            }
            if historySync.hasFullDiskAccess != true {
                Text("Needed to read WhatsApp and Mail history. macOS has no permission prompt for it: " +
                     "add this copy of Cotabby to the Full Disk Access list and switch it on. If macOS offers " +
                     "Quit & Reopen afterwards, choose Later; Cotabby notices the change by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This copy: \(Self.abbreviated(Bundle.main.bundlePath))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Button("Open Full Disk Access Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Show Cotabby in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .help("Drag this app into the Full Disk Access list.")
                Button("Check Again") { historySync.checkFullDiskAccess() }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch historySync.hasFullDiskAccess {
        case true?:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case false?:
            Label("Not granted", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case nil:
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
