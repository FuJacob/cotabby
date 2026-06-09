import SwiftUI

/// File overview:
/// Modal sheet listing the third-party packages Cotabby ships with. Lightweight by design: each
/// row names the project, summarizes what it does for Cotabby, and links to its repo. The intent
/// is attribution, not a full license dump; the GitHub repo carries the verbatim license texts.
struct AcknowledgementsView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.entries) { entry in
                        AcknowledgementRow(entry: entry)
                    }
                    Text(
                        "Each project ships under its own license; see the linked repository for the "
                        + "verbatim text."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Acknowledgements")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private static let entries: [AcknowledgementEntry] = [
        AcknowledgementEntry(
            name: "llama.cpp",
            summary: "On-device inference engine for GGUF models on the Open Source path.",
            url: "https://github.com/ggml-org/llama.cpp"
        ),
        AcknowledgementEntry(
            name: "Sparkle",
            summary: "Update framework used by the Check for Updates button.",
            url: "https://github.com/sparkle-project/Sparkle"
        ),
        AcknowledgementEntry(
            name: "swift-log",
            summary: "Logging façade Cotabby uses across runtime, focus, and suggestion subsystems.",
            url: "https://github.com/apple/swift-log"
        ),
        AcknowledgementEntry(
            name: "SymSpell",
            summary: "Symmetric-delete spelling correction (MIT, by Wolf Garbe), ported to Swift for "
                + "inline autocorrect. Bundled language dictionaries derive from Google Books Ngram "
                + "data (CC BY 3.0) and licensed SCOWL/Hunspell word lists. See "
                + "THIRD_PARTY_LICENSES.md for the notices.",
            url: "https://github.com/wolfgarbe/SymSpell"
        ),
        AcknowledgementEntry(
            name: "CotabbyInference",
            summary: "Swift wrapper around llama.cpp that exposes the inference API Cotabby links against.",
            url: "https://github.com/FuJacob/cotabbyinference"
        )
    ]
}

private struct AcknowledgementEntry: Identifiable {
    let name: String
    let summary: String
    let url: String

    var id: String { name }
}

private struct AcknowledgementRow: View {
    let entry: AcknowledgementEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                if let url = URL(string: entry.url) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Text(entry.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
