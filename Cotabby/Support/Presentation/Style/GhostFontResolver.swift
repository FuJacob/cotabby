import AppKit
import Foundation

/// File overview:
/// Picks the font the ghost text is drawn in. The goal is the host's exact typeface at the host's
/// exact size, because that is the only way the ghost glyphs occupy the same pixels the real text
/// will occupy once accepted. Every step below prefers a measured fact over a guess:
///
/// 1. A reported PostScript face (`Menlo-Regular`, `.AppleSystemUIFont`) at the reported size.
/// 2. A reported family at the reported size.
/// 3. A reported size with no family (Chromium): the host's rendered width of the text just before
///    the caret is compared against a small candidate set of common web/system faces at that size,
///    and the face whose advances reproduce the measured width wins. With no match, the system face
///    is scaled so its average advance matches the measurement; without a measurement it is used
///    as is.
/// 4. No size at all: the size is solved from the caret box height using the renderer's own line
///    metric (TextKit's default line height, or the web engine's rounded content area), then
///    width-calibrated when a sample exists.
///
/// The old design derived every ghost size from caret height with a 14pt legibility floor; that
/// floor is exactly why a 12pt host got 14pt ghost glyphs that overshot each accepted word. There
/// is no floor here: the host's size is the ghost's size. The user's Ghost Text Size multiplier
/// still applies when it is not 1, since that is an explicit request to differ from the host.
enum GhostFontResolver {
    /// Where the resolved font came from, for telemetry. Lets a misaligned ghost in a field report be
    /// traced to "the host named no font and the width match failed" rather than guessed at.
    enum Provenance: String, Equatable, Sendable {
        case hostFace = "host_face"
        case hostFamily = "host_family"
        case hostSizeMatchedFamily = "host_size_matched_family"
        case hostSizeScaledSystem = "host_size_scaled_system"
        case hostSizeSystem = "host_size_system"
        case caretDerived = "caret_derived"
        case caretDerivedCalibrated = "caret_derived_calibrated"
        /// The host named its face, but its measured text runs wider or narrower than that face at
        /// the reported size (Xcode's editor renders SF Mono 12 with 7.42pt advances); the face is
        /// kept and its size scaled to the measurement.
        case hostFaceScaled = "host_face_scaled"
        /// The face was identified from the host's own pixels (`TypefaceMatcher`) because the host
        /// named none and answered no width query.
        case pixelMatched = "pixel_matched"

        /// True when the face is a stand-in the host never named; a pixel match may replace it.
        var isFallbackFace: Bool {
            switch self {
            case .hostSizeSystem, .hostSizeScaledSystem, .caretDerived, .caretDerivedCalibrated:
                return true
            case .hostFace, .hostFamily, .hostSizeMatchedFamily, .pixelMatched, .hostFaceScaled:
                return false
            }
        }
    }

    struct Resolution: Equatable {
        let font: NSFont
        let provenance: Provenance
        /// Ratio between the host's measured sample width and this font's width of the same text.
        /// 1 when no sample existed. Values far from 1 mean the typeface differs from the host's.
        let widthAgreement: CGFloat
    }

    struct Input {
        let style: ResolvedFieldStyle?
        let hostMetrics: HostTextMetrics?
        /// Height of the host's caret box, the only size signal when the host names no size.
        let caretBoxHeight: CGFloat
        let renderer: GhostBaselinePolicy.HostRenderer
        /// The user's Ghost Text Size setting; 1 means "match the host".
        let sizeMultiplier: CGFloat

        init(
            style: ResolvedFieldStyle?,
            hostMetrics: HostTextMetrics?,
            caretBoxHeight: CGFloat,
            renderer: GhostBaselinePolicy.HostRenderer,
            sizeMultiplier: CGFloat = 1
        ) {
            self.style = style
            self.hostMetrics = hostMetrics
            self.caretBoxHeight = caretBoxHeight
            self.renderer = renderer
            self.sizeMultiplier = sizeMultiplier
        }
    }

    /// Faces the width match tries when a web host reports a size but no family. Ordered by how
    /// often they are the real answer on macOS web pages; ties in width agreement go to the earlier
    /// entry. Arial shares Helvetica's advances, so it needs no separate entry.
    static let candidateFamilies: [String] = [
        "Helvetica",
        "Menlo",
        "Georgia",
        "Times New Roman",
        "Verdana",
        "Courier New",
        "Trebuchet MS",
        "Avenir Next",
        "SF Mono"
    ]

    /// Relative width error below which a candidate face is accepted as the host's typeface.
    private static let widthMatchTolerance: CGFloat = 0.02
    /// Bounds for scaling the system face to a measured average advance, so one noisy measurement
    /// cannot produce absurd sizes.
    private static let minimumScale: CGFloat = 0.7
    private static let maximumScale: CGFloat = 1.4
    private static let minimumPointSize: CGFloat = 6
    private static let maximumPointSize: CGFloat = 96

    static func resolve(_ input: Input) -> Resolution {
        let base = resolveHostFont(input)
        guard input.sizeMultiplier > 0, abs(input.sizeMultiplier - 1) > 0.001 else {
            return base
        }
        let scaledSize = clampedSize(base.font.pointSize * input.sizeMultiplier)
        let scaled = NSFont(descriptor: base.font.fontDescriptor, size: scaledSize) ?? base.font
        return Resolution(font: scaled, provenance: base.provenance, widthAgreement: base.widthAgreement)
    }

    // MARK: - Host-reported faces

    private static func resolveHostFont(_ input: Input) -> Resolution {
        let reportedSize = plausibleReportedSize(input)
        if let reportedSize {
            if let name = input.style?.fontName, let font = font(named: name, size: reportedSize) {
                return fittedToSample(font, provenance: .hostFace, input)
            }
            if let family = input.style?.fontFamily, let font = font(family: family, size: reportedSize) {
                return fittedToSample(font, provenance: .hostFamily, input)
            }
            // The host named a face this Mac does not have (Gemini names its bundled Google Sans;
            // web pages name their webfonts). Guessing an installed family from one width sample is
            // wrong by construction: the real face is known and it is none of the candidates.
            // Measured in Gemini, that guess walked through Trebuchet, Georgia and Helvetica as
            // the sample changed. The system face scaled to the host's width is the honest stand-in.
            if input.style?.fontName != nil || input.style?.fontFamily != nil {
                return scaledSystem(reportedSize, input)
            }
            return resolveBySize(reportedSize, input)
        }
        return resolveFromCaretBox(input)
    }

    /// The system face at the host's size, scaled to the width sample when there is one.
    private static func scaledSystem(_ size: CGFloat, _ input: Input) -> Resolution {
        let systemFont = NSFont.systemFont(ofSize: size)
        guard let sample = input.hostMetrics?.sampleText, let sampleWidth = input.hostMetrics?.sampleWidth,
              sampleWidth > 0, !sample.isEmpty else {
            return Resolution(font: systemFont, provenance: .hostSizeSystem, widthAgreement: 1)
        }
        let scaled = scaledToSample(systemFont, sample: sample, width: sampleWidth)
        return Resolution(font: scaled, provenance: .hostSizeScaledSystem, widthAgreement: widthAgreement(of: scaled, input))
    }

    /// A named face is trusted as is unless the host's own measured text disagrees with it by more
    /// than rounding allows, in which case the face is kept and its size follows the measurement.
    private static func fittedToSample(_ font: NSFont, provenance: Provenance, _ input: Input) -> Resolution {
        let agreement = widthAgreement(of: font, input)
        guard abs(agreement - 1) > namedFaceScaleTolerance,
              let sample = input.hostMetrics?.sampleText, let sampleWidth = input.hostMetrics?.sampleWidth,
              sampleWidth > 0, !sample.isEmpty
        else {
            return Resolution(font: font, provenance: provenance, widthAgreement: agreement)
        }
        let scaled = scaledToSample(font, sample: sample, width: sampleWidth)
        return Resolution(font: scaled, provenance: .hostFaceScaled, widthAgreement: widthAgreement(of: scaled, input))
    }

    /// Width disagreement a named face may show before its size is scaled: AX widths are rounded to
    /// whole points, so a 32-character sample carries up to ~0.5% of rounding noise.
    private static let namedFaceScaleTolerance: CGFloat = 0.015

    /// The reported size, or nil when the host reported none or its value cannot describe glyphs
    /// that fit the caret box (an AX implementation that vends a stale or default size).
    private static func plausibleReportedSize(_ input: Input) -> CGFloat? {
        guard let size = input.style?.fontPointSize, size >= minimumPointSize, size <= maximumPointSize else {
            return nil
        }
        guard input.caretBoxHeight > 0 else {
            return size
        }
        // A caret box is rarely more than ~2x the glyph content area (loose CSS line-height); a box
        // far taller than that is not this size's line, and the box is the measurement to trust.
        // A box SHORTER than the content area is the other way round: real text never paints in a
        // line shorter than its glyphs, so such a box is not the text's line at all (measured
        // 2026-09-10: VS Code's hidden textarea reported an 8.5pt caret box for its 14pt editor and
        // 48 ghosts rendered at 7pt), and the reported size stands.
        let probe = font(named: input.style?.fontName ?? "", size: size) ?? NSFont.systemFont(ofSize: size)
        let contentHeight = probe.ascender - probe.descender
        guard contentHeight * 2.2 >= input.caretBoxHeight else {
            return nil
        }
        return size
    }

    /// Size known, face unknown: match the measured width against the candidate faces, else scale.
    private static func resolveBySize(_ size: CGFloat, _ input: Input) -> Resolution {
        let systemFont = NSFont.systemFont(ofSize: size)
        guard let sample = input.hostMetrics?.sampleText, let sampleWidth = input.hostMetrics?.sampleWidth,
              sampleWidth > 0, !sample.isEmpty else {
            return Resolution(font: systemFont, provenance: .hostSizeSystem, widthAgreement: 1)
        }
        var best: (font: NSFont, error: CGFloat) = (systemFont, relativeError(of: systemFont, sample: sample, width: sampleWidth))
        for family in candidateFamilies {
            guard let candidate = font(family: family, size: size) else { continue }
            let error = relativeError(of: candidate, sample: sample, width: sampleWidth)
            if error < best.error {
                best = (candidate, error)
            }
        }
        if best.error <= widthMatchTolerance {
            let provenance: Provenance = best.font.familyName == systemFont.familyName ? .hostSizeSystem : .hostSizeMatchedFamily
            return Resolution(font: best.font, provenance: provenance, widthAgreement: widthAgreement(of: best.font, input))
        }
        let scaled = scaledToSample(systemFont, sample: sample, width: sampleWidth)
        return Resolution(font: scaled, provenance: .hostSizeScaledSystem, widthAgreement: widthAgreement(of: scaled, input))
    }

    // MARK: - Evidence across samples

    /// Whether `family` reproduces one host width sample within the match tolerance. The unit of
    /// evidence `TypefaceEvidence` judges a field's samples with; same rule as the single-sample
    /// match in `resolveBySize`, so the two never disagree about what "fits" means.
    static func familyFits(_ family: String, sample: String, width: CGFloat, size: CGFloat) -> Bool {
        guard width > 0, !sample.isEmpty, let candidate = font(family: family, size: size) else { return false }
        return relativeError(of: candidate, sample: sample, width: width) <= widthMatchTolerance
    }

    /// The system face scaled to a sample: what a field renders in once its samples have ruled
    /// out every candidate family.
    static func scaledSystemResolution(size: CGFloat, sample: String, width: CGFloat) -> Resolution {
        let systemFont = NSFont.systemFont(ofSize: size)
        guard width > 0, !sample.isEmpty else {
            return Resolution(font: systemFont, provenance: .hostSizeSystem, widthAgreement: 1)
        }
        let scaled = scaledToSample(systemFont, sample: sample, width: width)
        let measured = self.width(of: sample, font: scaled)
        return Resolution(
            font: scaled, provenance: .hostSizeScaledSystem, widthAgreement: measured > 0 ? width / measured : 1
        )
    }

    /// A candidate family at a size, public so the evidence rule can re-render in the family it
    /// settled on.
    static func familyFont(_ family: String, size: CGFloat) -> NSFont? {
        font(family: family, size: size)
    }

    // MARK: - Caret-derived size

    /// No usable size from the host: solve the size whose renderer line metric equals the caret box.
    private static func resolveFromCaretBox(_ input: Input) -> Resolution {
        let face = input.style?.fontName.flatMap { font(named: $0, size: 12) }
            ?? input.style?.fontFamily.flatMap { font(family: $0, size: 12) }
            ?? NSFont.systemFont(ofSize: 12)
        let boxHeight = input.caretBoxHeight > 0 ? input.caretBoxHeight : 17
        let reference = NSFont(descriptor: face.fontDescriptor, size: 100) ?? NSFont.systemFont(ofSize: 100)
        let unitHeight: CGFloat
        switch input.renderer {
        case .textKit:
            unitHeight = NSLayoutManager().defaultLineHeight(for: reference) / 100
        case .webEngine:
            unitHeight = (reference.ascender - reference.descender) / 100
        }
        let solvedSize = clampedSize((boxHeight / max(unitHeight, 0.01)).rounded(toNearest: 0.5))
        let derived = NSFont(descriptor: face.fontDescriptor, size: solvedSize) ?? NSFont.systemFont(ofSize: solvedSize)
        guard let sample = input.hostMetrics?.sampleText, let sampleWidth = input.hostMetrics?.sampleWidth,
              sampleWidth > 0, !sample.isEmpty else {
            return Resolution(font: derived, provenance: .caretDerived, widthAgreement: 1)
        }
        let calibrated = scaledToSample(derived, sample: sample, width: sampleWidth)
        return Resolution(font: calibrated, provenance: .caretDerivedCalibrated, widthAgreement: widthAgreement(of: calibrated, input))
    }

    // MARK: - Helpers

    /// Resolves a PostScript name, routing the dotted system faces through the proper system-font API
    /// (CoreText refuses `.SFNS-Regular` by name and substitutes Times).
    static func font(named name: String, size: CGFloat) -> NSFont? {
        guard !name.isEmpty else { return nil }
        // SF Mono (Xcode's editor face, "SFMono-Medium") is not registered under its PostScript
        // name; like the dotted system faces it is only reachable through the system-font API.
        if name.hasPrefix(".") || name.hasPrefix("SFMono") {
            if name.localizedCaseInsensitiveContains("mono") {
                return NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight(in: name))
            }
            return NSFont.systemFont(ofSize: size, weight: systemWeight(in: name))
        }
        return NSFont(name: name, size: size)
    }

    static func font(family: String, size: CGFloat) -> NSFont? {
        guard !family.isEmpty else { return nil }
        if family == "SF Mono" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if family.hasPrefix(".") || family.localizedCaseInsensitiveContains("system") {
            return NSFont.systemFont(ofSize: size)
        }
        if let direct = NSFont(name: family, size: size), direct.familyName == family {
            return direct
        }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }

    private static func systemWeight(in name: String) -> NSFont.Weight {
        let lowered = name.lowercased()
        if lowered.contains("bold") { return .bold }
        if lowered.contains("semibold") { return .semibold }
        if lowered.contains("medium") { return .medium }
        if lowered.contains("light") { return .light }
        return .regular
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func relativeError(of font: NSFont, sample: String, width: CGFloat) -> CGFloat {
        let measured = self.width(of: sample, font: font)
        guard measured > 0 else { return .greatestFiniteMagnitude }
        return abs(measured - width) / width
    }

    /// Scales `font` so its width of `sample` matches the host's measurement. Iterated because the
    /// system font applies size-dependent tracking, so advances do not scale linearly with point
    /// size; two refinement passes land within a fraction of a percent.
    private static func scaledToSample(_ font: NSFont, sample: String, width: CGFloat) -> NSFont {
        var current = font
        for _ in 0..<3 {
            let measured = self.width(of: sample, font: current)
            guard measured > 0 else { return current }
            let scale = min(max(width / measured, minimumScale), maximumScale)
            guard abs(scale - 1) > 0.003 else { return current }
            let size = clampedSize(current.pointSize * scale)
            guard let next = NSFont(descriptor: current.fontDescriptor, size: size) else { return current }
            current = next
        }
        return current
    }

    private static func widthAgreement(of font: NSFont, _ input: Input) -> CGFloat {
        guard let sample = input.hostMetrics?.sampleText, let sampleWidth = input.hostMetrics?.sampleWidth,
              sampleWidth > 0, !sample.isEmpty else {
            return 1
        }
        let measured = width(of: sample, font: font)
        guard measured > 0 else { return 1 }
        return sampleWidth / measured
    }

    private static func clampedSize(_ size: CGFloat) -> CGFloat {
        min(max(size, minimumPointSize), maximumPointSize)
    }
}

private extension CGFloat {
    func rounded(toNearest step: CGFloat) -> CGFloat {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}
