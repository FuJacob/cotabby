import SwiftUI

/// File overview:
/// The card that offers a drafted answer to a question: the draft, then the messages it was drawn
/// from, then how to take or leave it.
///
/// Why the sources are always shown: an answer can quote facts from a different conversation than
/// the one being replied in (the user chose that for answers), so the card names every fact's
/// sender, chat, date and app, and which message it answers, before anything is inserted.
/// Presentation only; built by `AnswerCardController` from an `AnswerOffer` (`AnswerAttribution`).
/// The whole card is the insert button: a click pastes the draft at the caret, where the user edits
/// it.
struct AnswerCardView: View {
    let offer: AnswerOffer
    /// Whether Tab inserts too (an empty reply), or only a click (ghost text owns Tab there).
    var tabInserts = true
    var onInsert: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Answer from memory").font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(tabInserts ? "Click or Tab to insert · Esc to dismiss" : "Click to insert · Esc to dismiss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Answering \(offer.answering)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(offer.draft)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !offer.sources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(offer.sources) { source in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if source.isFromAnotherConversation {
                                    // The person being answered may not have seen this message.
                                    Label("Other conversation", systemImage: "arrow.triangle.branch")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                                Text(source.byline)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(source.excerpt)
                                .font(.caption)
                                .lineLimit(3)
                                .help(source.excerpt)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: onInsert)
        .padding(2)
    }
}
