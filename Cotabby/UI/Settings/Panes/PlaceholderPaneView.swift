import SwiftUI

/// File overview:
/// Stand-in detail pane used while the redesigned panes are being built out across the multi-PR
/// stack. Each subsequent PR replaces one of these with a real pane. Keeping a placeholder shape
/// in the scaffold PR means the container renders correctly even when only the framework is wired.
struct PlaceholderPaneView: View {
    let category: SettingsCategory

    var body: some View {
        SettingsPaneScaffold {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(category.label, systemImage: category.systemImage)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))

                    Text("This pane is being moved into the new Settings layout in an upcoming change.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
        }
    }
}
