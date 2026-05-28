import SwiftUI

/// File overview:
/// Shared chrome for every settings detail pane. Pulls the form styling, scroll wrapping, and
/// optional top-of-pane callout into one place so individual panes stay focused on their rows
/// rather than repeating layout boilerplate.
///
/// Why a callout slot:
/// The legacy settings window puts a single attention banner at the top of the form. The redesign
/// surfaces attention per pane: when a pane is in a degraded state (missing permission, runtime
/// unavailable) we render an inline callout above the form so the actionable surface lives next to
/// the controls that fix it.
struct SettingsPaneScaffold<Content: View>: View {
    let callout: SettingsPaneCallout?
    @ViewBuilder let content: () -> Content

    init(
        callout: SettingsPaneCallout? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.callout = callout
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let callout {
                    SettingsCalloutView(callout: callout)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                Form {
                    content()
                }
                .formStyle(.grouped)
                // `.formStyle(.grouped)` only pads BEFORE a `Section` that has a header. Panes
                // whose first section is header-less (General, About, Apps) would otherwise butt
                // flush against the title bar. A fixed top inset gives every pane the same
                // breathing room regardless of whether the first section carries a header.
                .padding(.top, 12)
            }
        }
    }
}

struct SettingsPaneCallout: Equatable {
    enum Tone {
        case warning
        case info
    }

    let tone: Tone
    let message: String
}

private struct SettingsCalloutView: View {
    let callout: SettingsPaneCallout

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .imageScale(.medium)

            Text(callout.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch callout.tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch callout.tone {
        case .warning: return .orange
        case .info: return .accentColor
        }
    }
}
