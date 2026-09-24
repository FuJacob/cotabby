import AppKit
import CoreGraphics
import Foundation

/// File overview:
/// Identifies the typeface AND size a host painted from the host's own pixels, for fields that
/// name no font or whose reported size cannot be trusted.
///
/// Chromium contenteditables (Gmail, Slack, Notion, Docs-style editors) report a font size and
/// nothing else: no family, and `AXBoundsForRange` returns an empty rect, so the width match in
/// `GhostFontResolver` has nothing to work with and the ghost falls back to the system face.
/// CodeMirror (Obsidian) and web views like ChatGPT's composer report no size either, and a size
/// derived from the caret box is only as good as the box: measured 2026-09-10, Obsidian's 16px
/// body came through as 17 and 20 and ChatGPT's 16px as 19, and a face matched at the wrong size
/// is confidently wrong (Times New Roman at 20 reproduced the advances of San Francisco at 16 and
/// scored 0.92). So the match searches over size as well as face: each candidate is rendered at a
/// grid of sizes around two centres, the caller's size and the size implied by the height of the
/// letter bodies the baseline analyzer found, right-aligned at the caret on the measured baseline,
/// and correlated column by column with the host's strip. A candidate whose letter bodies are not
/// the height the host painted is marked down however well its advances line up, which is what
/// separates a narrow face at a large size from a wide face at a small one. Pure (bitmap in, name
/// and size out) so it is tested against strips rendered in known faces at known sizes.
enum TypefaceMatcher {
    struct Input {
        /// Host pixels, row 0 at the top.
        let strip: RGBABitmap
        /// Device pixels per point.
        let scale: CGFloat
        /// Column (px) in the strip where the caret sits; the text ends there.
        let caretColumn: CGFloat
        /// Row (px) of the host's text baseline in the strip.
        let baselineRow: CGFloat
        /// The text immediately before the caret on its visual line, or as much of it as is known.
        let text: String
        /// The host's size as the caller believes it (an AX report or a caret-box derivation). One
        /// centre of the size search and nothing more.
        let pointSize: CGFloat
        /// Device-pixel height of the letter bodies in the strip, tallest ascender to baseline as
        /// `InkBaselineAnalyzer` measures them: the second centre of the size search, and the
        /// height every candidate rendering must reproduce. Nil when the caller measured none.
        var bodyRows: Int?
        /// True when `pointSize` is the host's own report (a CSS size, an AX font size) rather than
        /// a derivation from a caret box. A reported size narrows the search to its neighbourhood:
        /// serif faces are near-degenerate across sizes (Times New Roman at 19.5 reproduced a
        /// Georgia 18 strip in Chrome, measured 2026-09-10), and only an unknown size is worth
        /// that risk.
        var sizeIsReported: Bool = false
        /// Width in points of the host ink on the caret's line, when the caller measured it. The
        /// text rendered for a candidate is then trimmed from the left until it fits: a wrapped
        /// paragraph's tail runs back into the previous visual line, while the strip holds only
        /// the caret's line, and words that are not on screen cannot correlate with anything.
        var lineInkWidth: CGFloat?
        /// True when `pointSize` was scaled to a width the host itself rendered (a bounds query
        /// or the caret's own advance, see `CaretAdvanceSampler`). Such a size is within a couple
        /// of percent of the truth, tighter than any report: a zoomed page reports its CSS size and
        /// paints another (Claude's composer: 14 reported, 15.4 painted), so the search stays in
        /// the measured neighbourhood and the letter bodies no longer seed a second centre.
        var sizeIsMeasured: Bool = false
        /// PostScript names among `candidates` that the host itself ships (see
        /// `HostBundledFontRegistry`). A face the host bundles is not a guess about installed
        /// fonts, so the system face is not preferred over it on a near tie.
        var hostFontNames: Set<String> = []
        /// Faces to try, at any size; the search rescales them.
        let candidates: [NSFont]
    }

    struct Match: Equatable {
        let fontName: String
        let familyName: String
        /// The size at which the face reproduced the host's ink.
        let pointSize: CGFloat
        let score: Double
        let runnerUpScore: Double
        /// The system face's own best score in the same comparison (-1 when it was not a candidate).
        let systemScore: Double
        /// The stretch `advanceFitted` applied to the size the shapes chose; 1 when it left it.
        var advanceScale: CGFloat = 1
    }

    /// One candidate at its best size with its score. `Sendable` so the calibrator can carry a
    /// whole ranking out of its detached analysis and judge a later strip against the face it
    /// already recorded.
    struct Score: Equatable, Sendable {
        let fontName: String
        let familyName: String
        let pointSize: CGFloat
        let score: Double
    }

    /// The search's working unit: a candidate face at one size.
    private struct Ranked {
        let font: NSFont
        let pointSize: CGFloat
        let score: Double
    }

    /// Lowest normalized correlation accepted as "this is the face".
    static let minimumScore = 0.88
    /// Smallest lead over the next family required, so two faces that fit equally well resolve to
    /// the earlier, more common one only when it also fits the glyph shapes better.
    static let minimumMargin = 0.015
    /// Horizontal slack for the caret column, which Accessibility rounds to whole points, when a
    /// candidate is judged at its refined size.
    static let maximumLagPixels = 3
    /// Slack during the coarse size pass. The grid is 5% apart and the correlation tolerates only
    /// a few pixels of drift, so a face at a grid size 2% off its true size scored 0.23 while a
    /// wrong face at that size scored 0.85 (Chrome's address bar, 2026-09-10); the coarse pass must
    /// forgive the drift a coarse size implies, and the refinement removes it.
    static let coarseLagPixels = 10
    /// Columns right of the caret and the caret itself are never compared.
    static let caretGapPixels = 2
    /// Shorter text is too little evidence, and is declined before any candidate is rendered.
    static let minimumTextLength = 10
    /// Points of host ink a candidate must be compared over before its score counts. Measured
    /// 2026-09-10 in Obsidian: a strip holding "Hi Sarah," let Helvetica Neue at 16.66 edge out the
    /// system face at 16, and the field kept that face for 449 presentations; a dozen glyphs is
    /// where the families separate reliably.
    static let minimumEvidencePoints: CGFloat = 72
    /// When the system face scores within this of the leader it is the answer: it is what web
    /// content and native fields name by default, and a near tie against it on one strip is noise,
    /// not evidence of a rarer face (Arial 0.980 against the system face's 0.969, measured).
    static let systemPreferenceMargin = 0.03

    /// Ratios of a search centre tried in the coarse pass. The span covers the caret-box errors
    /// measured live (a 16px face asked for at 17, 19 and 20) with room to spare; the pass then
    /// narrows on the leaders.
    static let coarseSizeRatios: [CGFloat] = [0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.0, 1.05, 1.10, 1.16, 1.22, 1.28, 1.35, 1.42]
    /// The grid around a size the host reported itself: rounding and a scaled sample can move it
    /// a few percent, never a face size.
    static let reportedSizeRatios: [CGFloat] = [0.94, 0.97, 1.0, 1.03, 1.06]
    /// The grid around a size scaled to the host's own rendered width: the sample carries at most
    /// a percent or two of rounding.
    static let measuredSizeRatios: [CGFloat] = [0.97, 0.985, 1.0, 1.015, 1.03]
    /// The full line text is replaced by its last two words only when it clearly is not what the
    /// strip holds. A near miss is a face at the wrong size, not the wrong text: measured
    /// 2026-09-10 on Claude's composer, the true face led the full-text pass at 0.835 and the
    /// two-word pass ("it PERFECT.", eleven characters of capitals) handed the search to Helvetica
    /// Neue at 0.856, after which the system face reached 0.894 on those few glyphs.
    static let tailVariantCeiling = 0.72
    /// Rounds of narrowing around a candidate's best coarse size, every round for every candidate.
    /// The correlation is sharp in size: measured on a strip of Anthropic Sans at 15.4 (Claude's
    /// composer, 2026-09-10), the true face scored 0.95 at 15.40, 0.93 a twentieth of a point
    /// away, 0.86 a tenth away and 0.66 at the grid's 15.25, while Helvetica Neue reached 0.87 at
    /// some size of its own. Refining only the coarse leaders dropped the true face in fifth place
    /// unrefined, and a final step of 0.6% could still leave it a tenth of a point off; the last
    /// round is fine enough to land within a fiftieth.
    static let refinementRatios: [[CGFloat]] = [[0.975, 1.025], [0.9875, 1.0125], [0.994, 1.006], [0.997, 1.003]]
    /// A neighbouring size replaces the current one only when it scores this much higher. The
    /// correlation is jagged below a pixel (glyph origins snap), so a size a third of a percent
    /// off the truth can edge out the truth by a few thousandths; without this a Chrome field at
    /// a reported 18 refined to 18.054 and its ghost ran half a point long over a line
    /// (2026-09-10). Real moves clear it easily: a tenth of a point off the truth costs 0.05.
    static let refinementGain = 0.01
    /// Letter bodies (tallest ascender to baseline) span about this fraction of the point size in
    /// prose set in the common faces; it only centres the search, the grid absorbs the rest.
    static let bodyToPointSize: CGFloat = 0.72
    static let minimumPointSize: CGFloat = 6
    static let maximumPointSize: CGFloat = 96
    /// A candidate whose letter bodies differ from the host's by more than one device pixel loses
    /// this much score per extra pixel, down to a floor: enough to sink a wrong face at a wrong
    /// size (3px off scored 0.92 by advances alone) without touching an honest 1px rounding.
    static let bodyMismatchPenaltyPerPixel = 0.04
    static let bodyMismatchFloor = 0.7

    /// Families tried, most common first. The system face is always tried too.
    static let candidateFamilies: [String] = [
        "Helvetica", "Arial", "Helvetica Neue", "Georgia", "Times New Roman", "Verdana",
        "Menlo", "Courier New", "Trebuchet MS", "Avenir Next", "SF Mono"
    ]

    /// Families whose advances and shapes are close enough that the ghost looks the same in
    /// either; a tie between two of them is not a doubt about the answer.
    static let interchangeableFamilies: [Set<String>] = [
        ["Helvetica", "Arial", "Helvetica Neue"],
        ["Times New Roman", "Times"]
    ]

    static func defaultCandidates(pointSize: CGFloat) -> [NSFont] {
        var fonts: [NSFont] = [NSFont.systemFont(ofSize: pointSize)]
        for family in candidateFamilies {
            if let font = GhostFontResolver.font(family: family, size: pointSize) {
                fonts.append(font)
            }
        }
        return fonts
    }

    static func match(_ input: Input) -> Match? {
        match(from: rank(input), hostFontNames: input.hostFontNames)
    }

    /// The decision over a ranking: the leader must clear `minimumScore` and lead the next family
    /// by `minimumMargin`, unless that family is one the leader is interchangeable with. The
    /// system face takes a near tie from an installed candidate (the candidate list is a guess
    /// about what a web host might use, and the system face is the likeliest), never from a face
    /// the host ships in its own bundle.
    static func match(from ranked: [Score], hostFontNames: Set<String> = []) -> Match? {
        guard var winner = ranked.first, winner.score >= minimumScore else { return nil }
        let system = ranked.first { $0.familyName == systemFamilyName }
        let systemScore = system?.score ?? -1
        if let system, winner.familyName != systemFamilyName, !hostFontNames.contains(winner.fontName),
           systemScore >= winner.score - systemPreferenceMargin {
            winner = system
        }
        let runnerUp = ranked.first { $0.familyName != winner.familyName }
        let runnerUpScore = runnerUp?.score ?? -1
        if let runnerUp, winner.familyName != systemFamilyName, winner.score - runnerUp.score < minimumMargin {
            guard interchangeableFamilies.contains(where: { $0.contains(winner.familyName) && $0.contains(runnerUp.familyName) }) else {
                return nil
            }
        }
        return Match(
            fontName: winner.fontName,
            familyName: winner.familyName,
            pointSize: winner.pointSize,
            score: winner.score,
            runnerUpScore: runnerUpScore,
            systemScore: systemScore
        )
    }

    /// Every candidate at its best size, best first. Empty when the input carries too little text.
    static func rank(_ input: Input) -> [Score] {
        rankFonts(input).map {
            Score(fontName: $0.font.fontName, familyName: $0.font.familyName ?? $0.font.fontName, pointSize: $0.pointSize, score: $0.score)
        }
    }

    private static func rankFonts(_ input: Input) -> [Ranked] {
        guard HostLineText.tail(of: input.text).count >= minimumTextLength, !input.candidates.isEmpty else { return [] }
        // The strip must hold enough host ink left of the caret before a dozen faces at two dozen
        // sizes are rendered against it; a caret a few glyphs into its line is declined for free.
        let availableColumns = min(Int(input.caretColumn) - caretGapPixels, input.strip.width)
        guard CGFloat(availableColumns) >= minimumEvidencePoints * input.scale else { return [] }
        let sizes = searchSizes(input)
        guard !sizes.isEmpty else { return [] }
        var host = InkProfile.columns(of: input.strip)
        // Columns inked from top to bottom are not text (no glyph fills a line box); they are the
        // black an excluded window leaves in a capture, and at the caret end of the strip they
        // outweigh every glyph column. They are dropped from the comparison.
        let opaque = InkProfile.trailingOpaqueColumns(of: input.strip)
        if opaque > 0 {
            host.removeLast(min(opaque, host.count))
        }
        let variants = textVariants(HostLineText.tail(of: input.text))
        // Coarse pass with the full line text; only when nothing fits is the strip assumed to hold
        // just the tail after a soft wrap, and the pass repeated with the two-word variant. Running
        // both variants over every face and size doubled a search that competes with the model.
        var ranked = coarseRanking(candidates: input.candidates, sizes: sizes, variants: [variants[0]], host: host, input: input)
        var chosenVariants = [variants[0]]
        if variants.count > 1, (ranked.first?.score ?? -1) < tailVariantCeiling {
            let tail = coarseRanking(candidates: input.candidates, sizes: sizes, variants: [variants[1]], host: host, input: input)
            if (tail.first?.score ?? -1) > (ranked.first?.score ?? -1) {
                ranked = tail
                chosenVariants = [variants[1]]
            }
        }
        // Narrow the sizes with the tight lag, every candidate in every round: a coarse score is
        // the grid's fault as often as the face's, and the true face can trail a wrong one by a
        // fifth of the scale until its size is right (see `refinementRatios`).
        let scoring = Scoring(variants: chosenVariants, host: host, input: input)
        for (round, ratios) in refinementRatios.enumerated() {
            for index in ranked.indices {
                var best = ranked[index]
                let refined = scoreAt(best, ratios: [1.0] + ratios, scoring: scoring, lag: maximumLagPixels)
                if refined.score > best.score || round == 0 {
                    best = refined
                }
                ranked[index] = best
            }
            ranked.sort { $0.score > $1.score }
        }
        return ranked
    }

    private static func coarseRanking(
        candidates: [NSFont], sizes: [CGFloat], variants: [String], host: [Double], input: Input
    ) -> [Ranked] {
        var ranked: [Ranked] = []
        for candidate in candidates {
            var best = Ranked(font: candidate, pointSize: input.pointSize, score: -1)
            for size in sizes {
                let font = scaled(candidate, to: size)
                let score = score(font, variants: variants, host: host, input: input, lag: coarseLagPixels)
                if score > best.score {
                    best = Ranked(font: font, pointSize: size, score: score)
                }
            }
            ranked.append(best)
        }
        ranked.sort { $0.score > $1.score }
        return ranked
    }

    /// What a candidate rendering is scored against: the text variants, the host strip's column
    /// profile, and the input they came from.
    private struct Scoring {
        let variants: [String]
        let host: [Double]
        let input: Input
    }

    /// The best of `ranked` at each of its size times `ratios`, judged with `lag`. The ratio 1.0
    /// must come first: it re-scores the current size under the same lag so rounds compare like
    /// with like, and a neighbour only displaces it by clearing `refinementGain`.
    private static func scoreAt(_ ranked: Ranked, ratios: [CGFloat], scoring: Scoring, lag: Int) -> Ranked {
        var best = Ranked(font: ranked.font, pointSize: ranked.pointSize, score: -1)
        for (index, ratio) in ratios.enumerated() {
            let size = ranked.pointSize * ratio
            let font = scaled(ranked.font, to: size)
            let score = score(font, variants: scoring.variants, host: scoring.host, input: scoring.input, lag: lag)
            if index == 0 || score > best.score + refinementGain {
                best = Ranked(font: font, pointSize: size, score: score)
            }
        }
        return best
    }

    /// The sizes tried for every candidate: a coarse grid around the caller's size and, when the
    /// strip's letter bodies were measured, around the size they imply. Both centres are kept
    /// because either can be wrong: the caller's when the caret box is not the line, the bodies'
    /// when the line happens to carry no ascender.
    static func searchSizes(_ input: Input) -> [CGFloat] {
        var centres: [CGFloat] = []
        if input.pointSize > 0 {
            centres.append(input.pointSize)
        }
        if !input.sizeIsReported, !input.sizeIsMeasured, let rows = input.bodyRows, rows > 0, input.scale > 0 {
            centres.append(CGFloat(rows) / input.scale / bodyToPointSize)
        }
        let ratios = input.sizeIsMeasured ? measuredSizeRatios : (input.sizeIsReported ? reportedSizeRatios : coarseSizeRatios)
        var sizes: [CGFloat] = []
        for centre in centres {
            for ratio in ratios {
                let size = (centre * ratio * 4).rounded() / 4
                guard size >= minimumPointSize, size <= maximumPointSize else { continue }
                if !sizes.contains(where: { abs($0 - size) < 0.2 }) {
                    sizes.append(size)
                }
            }
        }
        return sizes.sorted()
    }

    private static let systemFamilyName = NSFont.systemFont(ofSize: 12).familyName ?? ".AppleSystemUIFont"

    /// The same face at another size. The system face goes through its own API so it keeps the
    /// optical-size variant AppKit would pick for that size.
    private static func scaled(_ font: NSFont, to size: CGFloat) -> NSFont {
        if font.familyName == systemFamilyName {
            return NSFont.systemFont(ofSize: size)
        }
        return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    private static func score(_ font: NSFont, variants: [String], host: [Double], input: Input, lag: Int) -> Double {
        var best = -1.0
        for variant in variants {
            let text = fitted(variant, font: font, lineInkWidth: input.lineInkWidth)
            guard let rendered = render(text, font: font, input: input) else { continue }
            best = max(best, correlate(host: host, rendered: rendered, input: input, lag: lag))
        }
        return best
    }

    /// Slack over the measured ink width before a leading word is dropped: the ink starts a side
    /// bearing after the pen and the caret sits one after the last glyph.
    static let lineFitSlack: CGFloat = 6

    /// `text` with leading words dropped until its advance in `font` fits the caret line's ink.
    static func fitted(_ text: String, font: NSFont, lineInkWidth: CGFloat?) -> String {
        guard let lineInkWidth, lineInkWidth > 0 else { return text }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var current = text
        while words.count > 1 {
            let advance = CGFloat(CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(NSAttributedString(string: current, attributes: [.font: font])), nil, nil, nil
            ))
            if advance <= lineInkWidth + lineFitSlack { break }
            words.removeFirst()
            current = words.joined(separator: " ")
        }
        return current
    }

    /// The full text and its last two words: when the caret sits shortly after a soft wrap the
    /// strip holds only the tail, and the shorter variant is what actually appears on screen.
    private static func textVariants(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var variants = [text]
        if words.count > 2 {
            variants.append(words.suffix(2).joined(separator: " "))
        }
        return variants
    }

    /// Renders `text` right-aligned so its advance ends at the caret column, on the host's baseline,
    /// into a bitmap the size of the strip. Black on white; only the ink profiles are used.
    private static func render(_ text: String, font: NSFont, input: Input) -> RGBABitmap? {
        let width = input.strip.width
        let height = input.strip.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: input.scale, y: input.scale)
            let penX = input.caretColumn / input.scale - advance
            let baselineY = (CGFloat(height) - input.baselineRow) / input.scale
            context.textPosition = CGPoint(x: penX, y: baselineY)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        return RGBABitmap(width: width, height: height, bytes: buffer)
    }

    /// Normalized cross-correlation of the column profiles over the columns the candidate covers,
    /// maximized over a few pixels of horizontal lag, then marked down when the candidate's letter
    /// bodies are not the height the host painted.
    private static func correlate(host: [Double], rendered: RGBABitmap, input: Input, lag maximumLag: Int) -> Double {
        let candidate = InkProfile.darkInkColumns(of: rendered)
        // The strip usually ends a little before the caret, so the caret column can lie past the
        // bitmap's right edge; never index beyond either profile.
        let end = min(Int(input.caretColumn) - caretGapPixels, host.count, candidate.count)
        guard end > 8 else { return -1 }
        // Compare only where the candidate put ink (its left edge), so a strip with more text to the
        // left than the variant does not penalize a correct face.
        let firstInk = candidate.firstIndex(where: { $0 > 0.5 }) ?? 0
        let start = max(0, firstInk - 2)
        guard CGFloat(end - start) >= minimumEvidencePoints * input.scale else { return -1 }
        var best = -1.0
        for lag in -maximumLag...maximumLag {
            var sumH = 0.0, sumC = 0.0, count = 0.0
            for column in start..<end {
                let hostColumn = column + lag
                guard hostColumn >= 0, hostColumn < host.count else { continue }
                sumH += host[hostColumn]
                sumC += candidate[column]
                count += 1
            }
            guard count > 0 else { continue }
            let meanH = sumH / count
            let meanC = sumC / count
            var numerator = 0.0, varianceH = 0.0, varianceC = 0.0
            for column in start..<end {
                let hostColumn = column + lag
                guard hostColumn >= 0, hostColumn < host.count else { continue }
                let deltaH = host[hostColumn] - meanH
                let deltaC = candidate[column] - meanC
                numerator += deltaH * deltaC
                varianceH += deltaH * deltaH
                varianceC += deltaC * deltaC
            }
            guard varianceH > 0, varianceC > 0 else { continue }
            best = max(best, numerator / (varianceH * varianceC).squareRoot())
        }
        guard best > 0, let hostBody = input.bodyRows, hostBody > 0 else { return best }
        let candidateBody = InkProfile.bodyRows(of: rendered, columns: start..<end)
        return best * bodyAgreement(hostRows: hostBody, candidateRows: candidateBody)
    }

    // MARK: - Advance fit

    /// Stretches tried when fitting the chosen face's advance to the host's glyph positions: a
    /// percent and a half either way, in steps of a twentieth of a percent.
    static let advanceFitScales: [CGFloat] = stride(from: 0.985, through: 1.01501, by: 0.0005).map { CGFloat($0) }
    /// Lowest correlation at which the fitted positions are trusted over the shape score's size.
    static let minimumAdvanceFitCorrelation = 0.85
    /// Points of host ink the fit needs: a shorter strip holds too few glyph positions to resolve
    /// a tenth of a percent.
    static let minimumAdvanceFitEvidencePoints: CGFloat = 120

    /// `match` with its size corrected to the host's glyph positions. The size search scores glyph
    /// shapes along with positions, and where a host's rasterizer paints stems a shade heavier than
    /// CoreText, a candidate one refinement step too large wins on shape: Chrome's Georgia at 18px
    /// matched 18.054 while the glyph positions in every strip put the host at CoreText's 17.99 to
    /// 18.00, and the ghost ran two device pixels long by the end of a line (measured 2026-09-10).
    /// Here the chosen face is rendered once and stretched about the caret column, never
    /// re-rendered, so its shapes cannot pull the answer: the stretch that lines its glyphs up with
    /// the host's is the host's advance relative to CoreText's. The match is returned unchanged
    /// when the strip is short or no stretch correlates well.
    static func advanceFitted(_ match: Match, input: Input) -> Match {
        guard let candidate = input.candidates.first(where: { $0.fontName == match.fontName }),
              let stretch = advanceScale(of: scaled(candidate, to: match.pointSize), input: input)
        else { return match }
        var fitted = Match(
            fontName: match.fontName,
            familyName: match.familyName,
            pointSize: min(max(match.pointSize * stretch, minimumPointSize), maximumPointSize),
            score: match.score,
            runnerUpScore: match.runnerUpScore,
            systemScore: match.systemScore
        )
        fitted.advanceScale = stretch
        return fitted
    }

    /// The stretch about the caret column that best lines `font`'s rendering of the strip's text
    /// up with the host's ink, over a few pixels of lag; nil when the strip holds too little text
    /// or no stretch correlates at `minimumAdvanceFitCorrelation`.
    static func advanceScale(of font: NSFont, input: Input) -> CGFloat? {
        let text = fitted(input.text, font: font, lineInkWidth: input.lineInkWidth)
        guard let rendered = render(text, font: font, input: input) else { return nil }
        let host = InkProfile.columns(of: input.strip)
        let candidate = InkProfile.darkInkColumns(of: rendered)
        let end = min(Int(input.caretColumn) - caretGapPixels, host.count, candidate.count)
        let firstInk = candidate.firstIndex(where: { $0 > 0.5 }) ?? 0
        let start = max(0, firstInk - 2)
        guard end > start, CGFloat(end - start) >= minimumAdvanceFitEvidencePoints * input.scale else { return nil }
        let caret = Double(input.caretColumn)
        let positions = Array(stride(from: Double(start), to: Double(end), by: 0.5))
        let hostSamples = positions.map { interpolated(host, at: $0) }
        var best = (score: -1.0, stretch: CGFloat(1))
        for stretch in advanceFitScales {
            for lagStep in -(maximumLagPixels * 4)...(maximumLagPixels * 4) {
                let lag = Double(lagStep) / 4
                let candidateSamples = positions.map { interpolated(candidate, at: caret + ($0 - caret) / Double(stretch) - lag) }
                let score = pearson(hostSamples, candidateSamples)
                if score > best.score {
                    best = (score, stretch)
                }
            }
        }
        guard best.score >= minimumAdvanceFitCorrelation else { return nil }
        return best.stretch
    }

    private static func interpolated(_ profile: [Double], at position: Double) -> Double {
        guard !profile.isEmpty, position >= 0, position <= Double(profile.count - 1) else { return 0 }
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, profile.count - 1)
        let fraction = position - Double(lower)
        return profile[lower] * (1 - fraction) + profile[upper] * fraction
    }

    private static func pearson(_ first: [Double], _ second: [Double]) -> Double {
        let count = Double(min(first.count, second.count))
        guard count > 1 else { return -1 }
        let meanFirst = first.reduce(0, +) / count
        let meanSecond = second.reduce(0, +) / count
        var numerator = 0.0, varianceFirst = 0.0, varianceSecond = 0.0
        for index in 0..<Int(count) {
            let deviationFirst = first[index] - meanFirst
            let deviationSecond = second[index] - meanSecond
            numerator += deviationFirst * deviationSecond
            varianceFirst += deviationFirst * deviationFirst
            varianceSecond += deviationSecond * deviationSecond
        }
        guard varianceFirst > 0, varianceSecond > 0 else { return -1 }
        return numerator / (varianceFirst * varianceSecond).squareRoot()
    }

    /// 1 when the candidate's letter bodies are within a device pixel of the host's, falling by
    /// `bodyMismatchPenaltyPerPixel` per further pixel to `bodyMismatchFloor`.
    static func bodyAgreement(hostRows: Int, candidateRows: Int) -> Double {
        let excess = max(0, abs(hostRows - candidateRows) - 1)
        return max(bodyMismatchFloor, 1 - bodyMismatchPenaltyPerPixel * Double(excess))
    }
}

/// Contrast-weighted ink profiles of a bitmap: how much each column differs from the background,
/// ignoring saturated pixels (colored carets, squiggles, link underlines). Integer arithmetic over
/// the raw bytes: a match renders a dozen candidate faces at a couple of dozen sizes and the work
/// must stay well under the model's own latency even in debug builds.
enum InkProfile {
    /// Saturation limit as (max - min) * 100 / max, in percent.
    static let maximumSaturationPercent = 35
    /// Ink darker than this (0...255 below white) counts as a body pixel in a candidate rendering;
    /// mirrors `InkBaselineAnalyzer.inkContrast` on the host side.
    static let candidateInkThreshold = 56
    /// Rows carrying at least this fraction of the busiest row's ink are letter bodies; mirrors
    /// `InkBaselineAnalyzer.bodyThreshold`.
    static let bodyThreshold = 0.35

    static func columns(of bitmap: RGBABitmap) -> [Double] {
        let width = bitmap.width
        let background = backgroundLuminance(of: bitmap)
        var profile = [Int](repeating: 0, count: width)
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                for column in 0..<width {
                    let offset = rowStart + column * 4
                    let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
                    let maxChannel = max(red, green, blue)
                    let minChannel = min(red, green, blue)
                    if maxChannel > 0, (maxChannel - minChannel) * 100 / maxChannel >= maximumSaturationPercent { continue }
                    profile[column] += abs(luminance(red, green, blue) - background)
                }
            }
        }
        return profile.map { Double($0) / 1000 }
    }

    /// Fraction of a column's rows that must be inked for the column to count as opaque (a
    /// blacked-out region, never a glyph: the tallest glyph spans about three quarters of a line
    /// box).
    static let opaqueColumnFraction = 0.95

    /// Number of consecutive opaque columns at the strip's right edge.
    static func trailingOpaqueColumns(of bitmap: RGBABitmap) -> Int {
        let width = bitmap.width, height = bitmap.height
        guard width > 0, height > 0 else { return 0 }
        let background = backgroundLuminance(of: bitmap)
        let needed = Int((Double(height) * opaqueColumnFraction).rounded(.up))
        var count = 0
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for column in stride(from: width - 1, through: 0, by: -1) {
                var inked = 0
                for row in 0..<height {
                    let offset = (row * width + column) * 4
                    let contrast = abs(luminance(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) - background)
                    if contrast > 56_000 { inked += 1 }
                }
                if inked >= needed { count += 1 } else { break }
            }
        }
        return count
    }

    /// Profile of a rendering known to be dark ink on a white ground (the candidate faces): no
    /// background estimate or saturation test needed.
    static func darkInkColumns(of bitmap: RGBABitmap) -> [Double] {
        let width = bitmap.width
        var profile = [Int](repeating: 0, count: width)
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                for column in 0..<width {
                    profile[column] += 255 - Int(bytes[rowStart + column * 4 + 1])
                }
            }
        }
        return profile.map { Double($0) / 255 }
    }

    /// Height in rows of the letter bodies of a dark-on-white rendering within `columns`: the
    /// first contiguous block of rows at least `bodyThreshold` as busy as the busiest row, the
    /// same rule `InkBaselineAnalyzer` applies to the host's strip. 0 when nothing was drawn.
    static func bodyRows(of bitmap: RGBABitmap, columns: Range<Int>) -> Int {
        let width = bitmap.width
        let lower = max(0, columns.lowerBound)
        let upper = min(width, columns.upperBound)
        guard lower < upper else { return 0 }
        var rowInk = [Int](repeating: 0, count: bitmap.height)
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                var count = 0
                for column in lower..<upper where 255 - Int(bytes[rowStart + column * 4 + 1]) > candidateInkThreshold {
                    count += 1
                }
                rowInk[row] = count
            }
        }
        guard let peak = rowInk.max(), peak > 0 else { return 0 }
        let threshold = bodyThreshold * Double(peak)
        guard let first = rowInk.indices.first(where: { Double(rowInk[$0]) >= threshold }) else { return 0 }
        var last = first
        while last + 1 < bitmap.height, Double(rowInk[last + 1]) >= threshold {
            last += 1
        }
        return last - first + 1
    }

    /// Luminance scaled by 1000 (0...255000).
    private static func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Int {
        (299 * red + 587 * green + 114 * blue)
    }

    /// Median luminance (scaled by 1000) from a 256-bin histogram of the green channel weighted
    /// luminance, so no per-pixel allocation or sort is needed.
    static func backgroundLuminance(of bitmap: RGBABitmap) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        let width = bitmap.width
        bitmap.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<bitmap.height {
                let rowStart = row * width * 4
                for column in 0..<width {
                    let offset = rowStart + column * 4
                    let lum = luminance(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) / 1000
                    histogram[min(max(lum, 0), 255)] += 1
                }
            }
        }
        let total = bitmap.width * bitmap.height
        var seen = 0
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen * 2 >= total { return value * 1000 }
        }
        return 0
    }
}

/// The part of the preceding text that can be on the caret's visual line: after the last hard
/// line break, bounded so long paragraphs cost nothing.
enum HostLineText {
    static let maximumLength = 48

    static func tail(of precedingText: String) -> String {
        let afterBreak: Substring
        if let breakIndex = precedingText.lastIndex(where: { $0.isNewline }) {
            afterBreak = precedingText[precedingText.index(after: breakIndex)...]
        } else {
            afterBreak = precedingText[...]
        }
        return String(afterBreak.suffix(maximumLength))
    }
}
