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
///
/// Search arrival:
/// When search reveals a specific setting, the scaffold scrolls to the row carrying the matching
/// `.settingsItem(_:)` anchor. The row's own modifier renders the pulse; the scaffold only owns
/// the scroll, so panes stay declarative.
struct SettingsPaneScaffold<Content: View>: View {
    let callout: SettingsPaneCallout?
    @ViewBuilder let content: () -> Content

    @Environment(\.settingsHighlightedItem) private var highlightedItem

    init(
        callout: SettingsPaneCallout? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.callout = callout
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
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
            .onAppear {
                // The pane is rebuilt on every sidebar switch (`.id(selection)` in the container),
                // so a search arrival lands here before rows have laid out. Two staggered attempts
                // instead of one timed guess: the first lands once typical layout has settled, the
                // second repairs the rare slow-machine case where layout finished late. `scrollTo`
                // to an already-centered anchor is a visual no-op, so the repair pass is invisible
                // whenever the first attempt worked.
                guard let item = highlightedItem else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
            }
            .onChange(of: highlightedItem) { _, item in
                // Same-pane reveals (a second search while already on the pane) skip onAppear, so
                // the scroll also rides the highlight change itself.
                guard let item else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(item, anchor: .center)
                }
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

/// Renders a single callout (warning/info) with a tinted background and matching icon. Used both by
/// the scaffold's top-of-pane slot and inline inside a pane section when an attention message belongs
/// next to a specific control (e.g. the Extended Context cost warning in the Advanced pane).
struct SettingsCalloutView: View {
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
