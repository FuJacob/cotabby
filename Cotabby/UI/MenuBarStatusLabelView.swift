import SwiftUI

/// File overview:
/// Renders the tiny always-visible menu-bar label. This view stays intentionally separate from
/// the larger menu content so the menu-bar extra can stay minimal even as the panel layout evolves.
///
/// This label lives in its own view because `MenuBarExtra` does not automatically observe
/// plain properties hanging off `AppDelegate`. By observing the activity model directly here,
/// SwiftUI knows when to redraw the menu bar item as Cotabby starts and finishes work.
///
/// The accepted word-count badge that used to live here is hidden for now; its source
/// (`SuggestionCoordinator.totalTabAcceptedWordCount`) and `WordCountFormatter` are intentionally
/// left intact so it can be restored — possibly as a count-when-idle, spinner-when-busy pairing.
struct MenuBarStatusLabelView: View {
    @ObservedObject var activityModel: MenuBarActivityModel

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarCatIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 16)

            if activityModel.isBusy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 16)
            }
        }
    }
}
