import AppKit
import CoreText

/// File overview:
/// The AppKit view that paints ghost text. It draws each `GhostTextLayout.Row` with CoreText at an
/// explicit baseline instead of hosting a SwiftUI `Text`, because SwiftUI's own line box places
/// glyphs by its internal line-height rules that do not match the host's. Here the baseline is a
/// number the layout computed from the host's caret box and the renderer's metric rule, so where
/// the glyphs land is fully determined by that number.
///
/// The view never decides anything: it receives a finished layout in global screen coordinates
/// plus the panel's screen origin and subtracts the two. Keeping the fractional offset inside the
/// view (rather than rounding the panel to whole points) preserves sub-pixel placement on Retina
/// displays, where the host itself positions glyphs at half-point boundaries.
final class GhostTextPanelView: NSView {
    struct Content {
        let layout: GhostTextLayout
        let textColor: NSColor
        /// The accept key printed inside the pill, or nil to skip the pill even if space was reserved.
        let keycapLabel: String?
        /// Global Cocoa origin of the panel this view fills.
        let panelOrigin: CGPoint
        let isDarkAppearance: Bool
    }

    var content: Content? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GhostTextPanelView is created in code")
    }

    override var isOpaque: Bool { false }

    /// Measures the pill for `label` so the layout can reserve exactly its width.
    static func keycapWidth(for label: String) -> CGFloat {
        let width = (label as NSString).size(withAttributes: [.font: keycapFont]).width
        return ceil(width) + keycapHorizontalPadding * 2
    }

    private static let keycapFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let keycapHorizontalPadding: CGFloat = 5

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        // Draw with the context exactly as AppKit hands it to any view: TextKit hosts render through
        // the same defaults (sub-pixel positioning with quantization, standard anti-aliasing), and
        // the pixel-alignment tests showed that overriding the quantization moved glyphs half a
        // device pixel off the host's.

        let origin = content.panelOrigin
        let attributes: [NSAttributedString.Key: Any] = [
            .font: content.layout.font,
            .foregroundColor: content.textColor
        ]
        for row in content.layout.rows where !row.text.isEmpty {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: row.text, attributes: attributes))
            context.textPosition = CGPoint(x: row.penX - origin.x, y: row.baselineY - origin.y)
            CTLineDraw(line, context)
        }

        if let keycapLabel = content.keycapLabel, let keycapFrame = content.layout.keycapFrame {
            drawKeycap(label: keycapLabel, in: keycapFrame.offsetBy(dx: -origin.x, dy: -origin.y), dark: content.isDarkAppearance)
        }
    }

    /// The accept-key pill: same colors the SwiftUI keycap used, so the hint looks unchanged.
    private func drawKeycap(label: String, in rect: CGRect, dark: Bool) {
        let background = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        let border = dark ? NSColor(white: 0.3, alpha: 1) : NSColor(white: 0.8, alpha: 1)
        let text = dark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        background.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributed = NSAttributedString(string: label, attributes: [.font: Self.keycapFont, .foregroundColor: text])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
