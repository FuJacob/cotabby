import AppKit
import Combine
import SwiftUI

/// File overview:
/// The selection-rewrite popup: the five tones, the "Fix spelling & grammar" tick box, the custom
/// instruction box, the cloud disclosure, and the preview with Replace / Copy / Retry and the
/// Shorter / Longer refinements. Presentation only:
/// every button calls back into `SelectionRewriteCoordinator` through `SelectionRewritePopupModel`.

/// What the popup shows, owned by the coordinator for one popup's lifetime.
///
/// `@MainActor` because SwiftUI reads these properties on the main thread and the coordinator writes
/// them there. `ObservableObject` plus `@Published` (a property wrapper that announces each change)
/// lets `SelectionRewritePopupView` redraw whenever the coordinator moves the popup to a new phase.
@MainActor
final class SelectionRewritePopupModel: ObservableObject {
    /// The popup's single visible state. The coordinator moves it forward as a rewrite runs.
    enum Phase: Equatable {
        case actions
        case generating(String)
        case preview(text: String, unsupported: [String])
        case failed(String)
        case notice(String)
    }

    @Published var phase: Phase = .actions
    /// The "Fix spelling & grammar" tick box; the coordinator seeds it from Settings and remembers changes.
    @Published var fixesMistakes = true
    /// "The selected text is sent to api.openai.com." when the provider is off-device.
    @Published var disclosure: String?
    @Published var customInstruction = ""

    // Callbacks are plain closures rather than a delegate protocol: the coordinator is the only
    // owner and wires each one once. The view never holds a reference back to the coordinator.
    var onAction: (RewriteAction) -> Void = { _ in }
    var onReplace: () -> Void = {}
    /// Replaces even though the rewrite changed a name or number the user wrote (see `changeWarning`).
    var onReplaceAnyway: () -> Void = {}
    /// What the rewrite changed that the user should check before replacing; nil when nothing did.
    @Published var changeWarning: String?
    var onCopy: () -> Void = {}
    var onRetry: () -> Void = {}
    /// Shorter / Longer on the preview: reshape the result on screen, keeping its tone.
    var onRefine: (RewriteAction) -> Void = { _ in }
    var onClose: () -> Void = {}
}

/// Renders `SelectionRewritePopupModel.phase` as one card. `@ObservedObject` subscribes the view to
/// the model it is given; the model is owned by the coordinator, so the view must not create it.
struct SelectionRewritePopupView: View {
    @ObservedObject var model: SelectionRewritePopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.phase {
            case .actions: actions
            case .generating(let partial): preview(partial.isEmpty ? "Rewriting…" : partial, final: false)
            case .preview(let text, let unsupported): previewResult(text, unsupported: unsupported)
            case .failed(let message): failure(message)
            case .notice(let message): Text(message).font(.callout).foregroundStyle(.secondary)
            }
            // The disclosure stays on screen in every phase: while the text is generating and in the
            // preview too, since the selected text is sent off-device whichever phase is showing.
            if let disclosure = model.disclosure { Text(disclosure).font(.caption).foregroundStyle(.orange) }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack {
            Label("Rewrite with AI", systemImage: "wand.and.stars").font(.headline)
            Spacer()
            Button { model.onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Who the text is for; typo fixing is the tick box below.
            WrapLayout(spacing: 6) {
                ForEach(RewriteAction.tones, id: \.self) { action in
                    Button(action.label) { model.onAction(action) }.buttonStyle(.bordered)
                }
            }
            Toggle("Fix spelling & grammar", isOn: $model.fixesMistakes)
            HStack {
                TextField("Custom instruction (e.g. make it warmer)", text: $model.customInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCustom() }
                Button("Go") { submitCustom() }.disabled(model.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitCustom() {
        let instruction = model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        model.onAction(.custom(instruction))
    }

    /// The rewrite as wrapped text. Short text is shown at its full height; text taller than
    /// `maximumPreviewHeight` scrolls inside a frame of exactly that height, so the buttons below
    /// always stay on screen. The height is given explicitly because the panel sizes itself to the
    /// view's fitting size, and a bare ScrollView has no ideal height (it would collapse to nothing).
    /// `final` false means the text is still streaming in, so it is drawn dimmed.
    @ViewBuilder
    private func preview(_ text: String, final: Bool) -> some View {
        let label = Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(final ? .primary : .secondary)
        if Self.previewNeedsScrolling(text) {
            ScrollView { label }.frame(height: Self.maximumPreviewHeight)
        } else {
            label
        }
    }

    /// The tallest the preview grows before it scrolls: about 18 lines, which with the rest of the
    /// popup fits on the smallest screens Cotabby supports.
    static let maximumPreviewHeight: CGFloat = 300
    /// The text's width inside the popup: the 360 pt card minus its 12 pt padding on each side.
    static let previewWidth: CGFloat = 336

    /// Whether `text` laid out at the preview's width and the system body font is taller than
    /// `maximumPreviewHeight`. Measured with TextKit rather than SwiftUI so the answer is known
    /// before layout and pinned by tests.
    static func previewNeedsScrolling(_ text: String) -> Bool {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let bounds = attributed.boundingRect(
            with: CGSize(width: previewWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return bounds.height > maximumPreviewHeight
    }

    private func previewResult(_ text: String, unsupported: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            preview(text, final: true)
            if !unsupported.isEmpty {
                // The rewrite changed a name or number the user wrote: say what, and let them decide.
                // "Replace anyway" is a deliberate click; Return does not trigger it.
                Text(model.changeWarning ?? "The rewrite changed: \(unsupported.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if unsupported.isEmpty {
                    Button("Replace") { model.onReplace() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Replace anyway") { model.onReplaceAnyway() }
                }
                Button("Copy") { model.onCopy() }
                Button("Retry") { model.onRetry() }
                Spacer()
                // Reshape this result, keeping the tone that produced it.
                ForEach(RewriteAction.refinements, id: \.self) { length in
                    Button(length.label) { model.onRefine(length) }
                }
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout)
            HStack {
                Button("Retry") { model.onRetry() }
                Spacer()
            }
        }
    }
}

/// Lays buttons out left to right and wraps onto a new line when the popup's width runs out, so
/// the tones need no fixed row split.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .greatestFiniteMagnitude)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var rowTop = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var cursorX = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: cursorX, y: rowTop), proposal: ProposedViewSize(size))
                cursorX += size.width + spacing
            }
            rowTop += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + extra > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
