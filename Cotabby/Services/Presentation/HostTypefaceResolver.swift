import AppKit
import Foundation
import Logging

/// File overview:
/// The face and size an inline ghost is drawn in for the field a geometry describes, and what each
/// field has measured about its host's typeface so far.
///
/// `GhostFontResolver` answers from one snapshot. A field is presented many times, though, and what
/// it showed earlier is better evidence than any one snapshot: the width samples it produced
/// (`TypefaceEvidence`), the size its caret's advance measured (`HostAdvanceFit`), the face its
/// pixels matched (`HostBaselineCalibrator`), and the face an earlier field of the same host style
/// settled on (`HostFaceMemory`, kept across launches). This type keeps that per-field and per-style
/// state and applies it, in a fixed order, to every resolution, so the overlay only asks for the
/// result and keeps to its panel.
///
/// Owned by `OverlayController` for the app's lifetime.
@MainActor
final class HostTypefaceResolver {
    private let suggestionSettings: SuggestionSettingsModel
    /// Where a field's pixel typeface match is recorded; nil where screen capture is unwanted (tests).
    private let baselineCalibrator: HostBaselineCalibrator?

    /// Called with a host font's name once `HostFontRegistry` made it loadable, so a ghost already
    /// drawn in its stand-in can be drawn again in it (see `requestHostFontIfNeeded`).
    var onHostFontRegistered: (@MainActor (String) -> Void)?

    /// What each field's width samples have said about its typeface so far (see `TypefaceEvidence`).
    /// Keyed by the field's session identity, which survives the field growing as text wraps.
    private var typefaceEvidence: [UInt64: TypefaceEvidence] = [:]
    /// Per field: the host's size measured from its own caret's advance along a line, for a web
    /// field that reports no size (see `HostAdvanceFit`, `applyingHostAdvance`).
    private var hostAdvanceFits: [UInt64: HostAdvanceFit] = [:]
    /// Fields whose host named a face this Mac cannot load (Gemini's bundled Google Sans). The
    /// name is not on every snapshot's style (Chromium answers only a size for some caret
    /// positions), and one nameless snapshot was enough to let a width match flash Georgia in the
    /// middle of an otherwise settled field. Once seen, the fact holds for the field's life.
    private var unavailableNamedFaceFields: Set<UInt64> = []
    /// The face each host text style last settled on, for fields that have measured nothing yet
    /// (see `HostFaceMemory`). Lives as long as this resolver, which is the app's lifetime.
    private var hostFaceMemory = HostFaceMemory()
    /// Which zoom ladder each host paints on, for snapping a pixel-matched size (see `HostZoomLadder`).
    private let hostZoomLadders = HostZoomLadderResolver()
    /// The faces an Electron host ships in its bundle, for the pixel match (see the registry). The
    /// overlay's calibration request offers them to the match, and a field in a host that bundles
    /// faces takes the scaled system face until the match names one (`markUnavailableNamedFace`).
    let hostBundledFonts = HostBundledFontRegistry()

    /// Where `hostFaceMemory` is kept between launches; nil keeps it in memory only (tests).
    private let faceMemoryDefaults: UserDefaults?
    static let faceMemoryDefaultsKey = "cotabbyHostFaceMemory"

    /// `"<bundle id>|<font name>"` pairs already handed to `HostFontRegistry`, so a font the host
    /// bundle does not contain is looked up once rather than on every render. Grows only with the
    /// number of distinct unresolvable fonts actually encountered, which is small.
    private var requestedHostFonts: Set<String> = []

    // Xcode 26.0-26.3 emits an isolated deinit for a stored-property @MainActor class whose
    // teardown double-frees when a test-scoped instance deallocates ("pointer being freed was not
    // allocated"). Nothing here needs main-actor cleanup, so a nonisolated deinit is equivalent.
    nonisolated deinit {}

    init(
        suggestionSettings: SuggestionSettingsModel,
        baselineCalibrator: HostBaselineCalibrator? = nil,
        faceMemoryDefaults: UserDefaults? = nil
    ) {
        self.suggestionSettings = suggestionSettings
        self.baselineCalibrator = baselineCalibrator
        self.faceMemoryDefaults = faceMemoryDefaults
        self.hostFaceMemory = HostFaceMemory(restoring: faceMemoryDefaults?.data(forKey: Self.faceMemoryDefaultsKey))
    }

    /// Saves the face memory after a record changed it (a new style settled, or its size or pitch
    /// moved): once per field at most, not once per presentation.
    private func saveFaceMemory() {
        faceMemoryDefaults?.set(hostFaceMemory.encoded(), forKey: Self.faceMemoryDefaultsKey)
    }

    // MARK: - Resolution

    /// The host's face by report or measurement; for a web field the host never named, a face the
    /// host's own pixels matched earlier in this field replaces the system stand-in. Not a pure
    /// read: every call records the field's evidence, may update the face memory and may start
    /// loading a host font, so adding or dropping a call changes what the field remembers.
    func resolveFont(
        for geometry: SuggestionOverlayGeometry,
        renderer: GhostBaselinePolicy.HostRenderer
    ) -> GhostFontResolver.Resolution {
        let resolution = GhostFontResolver.resolve(
            GhostFontResolver.Input(
                style: geometry.resolvedFieldStyle,
                hostMetrics: geometry.hostTextMetrics,
                caretBoxHeight: geometry.caretRect.height,
                renderer: renderer,
                sizeMultiplier: ghostSizeMultiplier
            )
        )
        let judged = applyingTypefaceEvidence(resolution, for: geometry)
        let zoom = zoomStep(for: geometry)
        let matched = Self.applyingMatchedTypeface(
            judged,
            match: baselineCalibrator?.cachedTypeface(for: typefaceKey(for: geometry)),
            hostNamesFace: Self.hostNamesFace(geometry),
            widthSample: heldWidthSample(for: geometry),
            sizeMultiplier: ghostSizeMultiplier,
            reportedSize: zoom.reportedSize,
            zoomKind: zoom.kind
        )
        let sized = applyingHostAdvance(matched, for: geometry)
        let remembered = rememberingHostFace(sized.resolution, advanceMeasured: sized.advanceMeasured, for: geometry)
        requestHostFontIfNeeded(for: geometry)
        return applyingUserSizeLimits(remembered)
    }

    /// The user's Ghost Text Size multiplier, or 1 when they asked for the host's own size. Every
    /// size path reads it through here, including the ones that divide it back out to recover the
    /// host size from a ghost size, so the two directions always agree.
    var ghostSizeMultiplier: CGFloat {
        suggestionSettings.matchesHostTextSize ? 1 : CGFloat(suggestionSettings.ghostTextSizeMultiplier)
    }

    /// `ghostSizeMultiplier` floored away from zero, for the paths that divide it back out of a
    /// ghost size to recover the host's (and the one that multiplies it back in).
    private var flooredSizeMultiplier: CGFloat { max(ghostSizeMultiplier, 0.01) }

    /// The user's ghost-size floor and ceiling (Settings → Appearance → Ghost Text Size Limits) are
    /// absolute bounds over whatever the host resolution produced: they say what the user is willing
    /// to read, so a host that reports 6pt or a runaway caret estimate cannot override them. The face
    /// and provenance stay as resolved; only the size moves, and `HostFaceMemory` already recorded
    /// the unclamped host size (`resolveFont`) so the field's own measurement is not polluted by the
    /// limit.
    private func applyingUserSizeLimits(_ resolution: GhostFontResolver.Resolution) -> GhostFontResolver.Resolution {
        // Matching the host's size sets the user's limits aside; only the legibility backstop stays.
        let matches = suggestionSettings.matchesHostTextSize
        let clamped = GhostFontSizeLimits.clamped(
            resolution.font.pointSize,
            floor: matches ? 0 : CGFloat(suggestionSettings.ghostFontSizeFloor),
            ceiling: matches ? 0 : CGFloat(suggestionSettings.ghostFontSizeCeiling)
        )
        guard abs(clamped - resolution.font.pointSize) > 0.01 else { return resolution }
        return GhostFontResolver.Resolution(
            font: GhostFontResolver.resized(resolution.font, to: clamped),
            provenance: resolution.provenance,
            widthAgreement: resolution.widthAgreement
        )
    }

    /// Asks `HostFontRegistry` to load a face the host names but this process cannot instantiate.
    /// Hosts that ship private fonts (Word's Aptos and Calibri live in its bundle and are installed
    /// nowhere on the system) would otherwise render ghost text in a stand-in face forever.
    /// Registration is deliberately not awaited: it does disk I/O that must not block a render, so
    /// the current frame keeps the stand-in and `onHostFontRegistered` has the ghost redrawn in the
    /// face once it loads. Only hosts on `HostFontRegistry`'s allowlist ever reach the registry,
    /// which also verifies the host's code signature before parsing anything: a focused app
    /// controls both the font name it reports and the files in its bundle, so any other app keeps
    /// the stand-in.
    private func requestHostFontIfNeeded(for geometry: SuggestionOverlayGeometry) {
        guard let name = geometry.resolvedFieldStyle?.fontName,
              GhostFontResolver.font(named: name, size: 12) == nil,
              let bundleIdentifier = geometry.bundleIdentifier,
              HostFontRegistry.isTrustedHost(bundleIdentifier: bundleIdentifier)
        else { return }
        // Ask at most once per (host, font) pair: this runs on every keystroke, so without the set a
        // typeface that genuinely is not in the host's bundle would spawn a throwaway Task per render.
        let requestKey = "\(bundleIdentifier)|\(name)"
        guard !requestedHostFonts.contains(requestKey),
              let bundleURL = runningHostBundleURL(for: bundleIdentifier)
        else { return }
        requestedHostFonts.insert(requestKey)
        Task { [weak self] in
            let registered = await HostFontRegistry.shared.ensureFontAvailable(
                named: name, bundleIdentifier: bundleIdentifier, bundleURL: bundleURL
            )
            guard registered else { return }
            self?.onHostFontRegistered?(name)
        }
    }

    /// The bundle the running host was launched from. Read from the process rather than looked up
    /// by identifier through LaunchServices, which can name a different copy of the app than the
    /// one the user is typing into. The focused field belongs to the frontmost app, so that instance
    /// wins when several share the identifier.
    private func runningHostBundleURL(for bundleIdentifier: String) -> URL? {
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier == bundleIdentifier {
            return frontmost.bundleURL
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL
    }

    /// A pixel-matched face in a web field that reports no size, or such a field's stand-in
    /// (`takesHostAdvance`), takes the size the field's own caret advance measured (`HostAdvanceFit`)
    /// or, until the field has measured one, the size an earlier field of the same style measured for
    /// the same face. The match's own size comes from a short
    /// strip whose size search is coarse, and its score says nothing about its size: Claude's Code
    /// composer matched 15.1585 with 0.97 where the host paints 15.336 (2026-09-11). A host that
    /// reports its size snaps the match to its zoom ladder instead (`applyingMatchedTypeface`).
    /// `advanceMeasured` marks the result for `HostFaceMemory`.
    private func applyingHostAdvance(
        _ resolution: GhostFontResolver.Resolution,
        for geometry: SuggestionOverlayGeometry
    ) -> (resolution: GhostFontResolver.Resolution, advanceMeasured: Bool) {
        guard Self.takesHostAdvance(resolution, for: geometry) else {
            return (resolution, false)
        }
        let size: CGFloat
        if let fit = hostAdvanceFits[geometry.focusedInputIdentityKey], fit.faceName == resolution.font.fontName,
           let adopted = fit.adopted {
            size = adopted.pointSize * flooredSizeMultiplier
        } else if let key = hostStyleKey(for: geometry), let remembered = hostFaceMemory.face(for: key),
                  remembered.advanceMeasured == true, remembered.fontName == resolution.font.fontName {
            // Kept with the multiplier applied, under a key that includes it.
            size = remembered.pointSize
        } else {
            return (resolution, false)
        }
        guard let font = GhostFontResolver.font(named: resolution.font.fontName, size: size) else {
            return (resolution, false)
        }
        // A face the pixels named keeps saying so; a stand-in whose size alone was fitted says that.
        let provenance: GhostFontResolver.Provenance = resolution.provenance == .pixelMatched ? .pixelMatched : .hostAdvanceFitted
        return (GhostFontResolver.Resolution(font: font, provenance: provenance, widthAgreement: 1), true)
    }

    /// Whether a web field's ghost takes its size from the field's own caret advance
    /// (`HostAdvanceFit`): only a field that reports no size, in a face its pixels named or in the
    /// stand-in. Chrome's address bar names no face, paints the system one, and answers no bounds
    /// query; its caret-derived stand-in ran 7% large (15.5 where the caret's own advance along
    /// five queries fitted 14.48 to 14.58, 2026-09-11), and no pixel match ever names its face.
    ///
    /// A paragraph's stand-in is included for the same reason, more strongly: its size is a guess
    /// from the line box, which assumes a line height near 1.17. Discord's composer sets 1.375, so
    /// the guess ran 19% large (20.5 where 17 captures along one line fitted 17.22, 2026-11-22) and
    /// no pixel match named its bundled face to correct it. The stand-in is not the host's family,
    /// so the fit is of its width, not its height; `HostAdvanceFit` bounds how far such a fit may
    /// move the size (see `caretBoxGuessMaximumShrink`).
    static func takesHostAdvance(
        provenance: GhostFontResolver.Provenance,
        isWebContentField: Bool,
        reportsSize: Bool
    ) -> Bool {
        guard isWebContentField, !reportsSize else { return false }
        return provenance == .pixelMatched || provenance.isFallbackFace
    }

    /// `takesHostAdvance` for a resolution in the field `geometry` describes.
    static func takesHostAdvance(_ resolution: GhostFontResolver.Resolution, for geometry: SuggestionOverlayGeometry) -> Bool {
        takesHostAdvance(
            provenance: resolution.provenance,
            isWebContentField: geometry.isWebContentField,
            reportsSize: geometry.resolvedFieldStyle?.fontPointSize != nil
        )
    }

    /// Feeds a fresh capture of the caret on a paragraph's first line to its field's advance fit
    /// (`HostAdvanceFit`): only for requests marked `recordsAdvance` (see `takesHostAdvance`), only
    /// a caret right after a glyph (a trailing space's advance is the ghost's own, not a
    /// measurement), and only the paragraph's first line, whose start every capture shares. The fit
    /// is taken in the ghost's face at the host size it assumes, the user's size multiplier divided
    /// out.
    func recordAdvanceCapture(_ measurement: PixelCaretLocator.Measurement, request: PixelCaretLocator.Request) {
        // A mid-line caret is placed from the ghost face's own advances, so it measures nothing.
        guard request.recordsAdvance, !request.caretIsMidLine, measurement.lineIndex == 0, let face = request.font,
              let last = request.paragraphTextBeforeCaret.last, !last.isWhitespace,
              !request.paragraphTextBeforeCaret.contains(where: \.isNewline),
              let hostFace = GhostFontResolver.font(named: face.fontName, size: face.pointSize / flooredSizeMultiplier)
        else { return }
        let identity = request.focusedInputIdentityKey
        var fit = hostAdvanceFits[identity] ?? HostAdvanceFit()
        let lineKey = "\(Int(request.runFrame.minX.rounded()))|\(Int(measurement.lineRect.maxY.rounded()))"
        let adopted = fit.record(
            text: request.paragraphTextBeforeCaret, caretX: measurement.caretRect.minX, lineKey: lineKey, face: hostFace,
            minimumSpan: request.advanceFitMinimumSpan, maximumShrink: request.advanceFitMaximumShrink
        )
        hostAdvanceFits[identity] = fit
        guard let adopted, CotabbyLogger.suggestion.logLevel <= .debug else { return }
        let assumedSize = Double(hostFace.pointSize)
        let fittedSize = Double(adopted.pointSize)
        let span = Double(adopted.span)
        let metadata: Logger.Metadata = [
            "stage": .string("advance-fit"),
            "identity": .stringConvertible(identity),
            "font": .string(hostFace.fontName),
            "assumed_size": .stringConvertible(assumedSize),
            "fitted_size": .stringConvertible(fittedSize),
            "span": .stringConvertible(span),
            "captures": .stringConvertible(adopted.captures),
            "refinements": .stringConvertible(fit.refinements)
        ]
        CotabbyLogger.suggestion.debug("Host advance fit adopted", metadata: metadata)
    }

    /// The reported CSS size and zoom ladder a web field's pixel-matched size snaps to (see
    /// `HostZoomLadder`). Every path that applies a pixel match goes through this, or a fresh
    /// calibration re-applies the raw fit for a presentation (Georgia 17.892 between 18.0 frames,
    /// once per streamed word, 2026-09-11).
    private func zoomStep(for geometry: SuggestionOverlayGeometry) -> (reportedSize: CGFloat?, kind: HostZoomLadder.Kind?) {
        guard geometry.isWebContentField else { return (nil, nil) }
        return (geometry.resolvedFieldStyle?.fontPointSize, hostZoomLadders.kind(forBundleIdentifier: geometry.bundleIdentifier))
    }

    /// The key `HostFaceMemory` files a field's host text style under.
    private func hostStyleKey(for geometry: SuggestionOverlayGeometry) -> HostFaceMemory.Key? {
        HostFaceMemory.Key(
            bundleIdentifier: geometry.bundleIdentifier,
            urlString: geometry.focusedURLString,
            isBrowser: BrowserAppDetector.isBrowser(bundleIdentifier: geometry.bundleIdentifier),
            reportedSize: geometry.resolvedFieldStyle?.fontPointSize,
            caretHeight: geometry.caretRect.height,
            sizeMultiplier: ghostSizeMultiplier
        )
    }

    /// Records a field's settled face for its host's text style, and starts a field that has
    /// measured nothing yet in the face its host's last field settled on (see `HostFaceMemory`).
    /// A host that names its face never needs this: the resolver has that face already.
    private func rememberingHostFace(
        _ resolution: GhostFontResolver.Resolution,
        advanceMeasured: Bool = false,
        for geometry: SuggestionOverlayGeometry
    ) -> GhostFontResolver.Resolution {
        guard !Self.hostNamesFace(geometry), let key = hostStyleKey(for: geometry) else {
            return resolution
        }
        let adoptedSample = typefaceEvidence[geometry.focusedInputIdentityKey]?.scalingSample != nil
        if HostFaceMemory.isSettled(resolution.provenance, fieldAdoptedSample: adoptedSample) {
            let face = HostFaceMemory.Face(
                fontName: resolution.font.fontName, pointSize: resolution.font.pointSize, advanceMeasured: advanceMeasured ? true : nil
            )
            if hostFaceMemory.record(face, for: key) {
                saveFaceMemory()
            }
            return resolution
        }
        guard HostFaceMemory.yieldsToMemory(resolution.provenance),
              let remembered = hostFaceMemory.face(for: key),
              let font = GhostFontResolver.font(named: remembered.fontName, size: remembered.pointSize)
        else {
            return resolution
        }
        return GhostFontResolver.Resolution(font: font, provenance: .hostRemembered, widthAgreement: 1)
    }

    /// The width sample a pixel match is sized to: the one the field adopted (the first long
    /// enough, held for the field's life, see `TypefaceEvidence.scalingAdoptionLength`), so a
    /// sample that grows with every poll cannot resize the ghost between presentations.
    private func heldWidthSample(for geometry: SuggestionOverlayGeometry) -> TypefaceEvidence.Sample? {
        typefaceEvidence[geometry.focusedInputIdentityKey]?.scalingSample ?? Self.widthSample(of: geometry)
    }

    /// Whether the host told us its face (even one this Mac cannot load).
    static func hostNamesFace(_ geometry: SuggestionOverlayGeometry) -> Bool {
        geometry.resolvedFieldStyle?.fontName != nil || geometry.resolvedFieldStyle?.fontFamily != nil
    }

    /// Holds a width-matched face steady across the samples a field produces over its life.
    ///
    /// Inert for a field measured once (the resolver's own decision stands untouched) and for any
    /// host whose named face loads. Two kinds of field reach the rules below:
    ///   - a host that named a face this Mac cannot load (Gemini names its bundled Google Sans):
    ///     once seen, the field renders the system face scaled to its longest sample for good,
    ///     even on snapshots whose style momentarily carries only a size, which is what let a width
    ///     match flash Georgia in the middle of an otherwise settled field;
    ///   - a size-only field that keeps producing new, different width samples, judged by
    ///     `TypefaceEvidence` (see the measured Gemini sequence there).
    ///
    /// Internal rather than private so tests can drive the per-field state it keeps.
    func applyingTypefaceEvidence(
        _ resolution: GhostFontResolver.Resolution,
        for geometry: SuggestionOverlayGeometry
    ) -> GhostFontResolver.Resolution {
        let identity = geometry.focusedInputIdentityKey
        switch resolution.provenance {
        case .hostSizeMatchedFamily, .hostSizeSystem, .hostSizeScaledSystem:
            break
        case .caretDerived, .caretDerivedCalibrated:
            // No face to judge here, but the field's samples are still recorded so the first one
            // long enough is held for a later pixel match to take its size from.
            if let sample = Self.widthSample(of: geometry) {
                var evidence = typefaceEvidence[identity] ?? TypefaceEvidence()
                Self.recordWidthSample(sample, in: &evidence, resolverFamily: nil, font: resolution.font, identity: identity)
                typefaceEvidence[identity] = evidence
            }
            return resolution
        default:
            return resolution
        }
        // `size` is the host's (the families are judged against the host's own widths); every
        // resolution built from it below takes the user's multiplier, which `resolution` already has.
        let multiplier = CGFloat(suggestionSettings.ghostTextSizeMultiplier)
        let size = geometry.resolvedFieldStyle?.fontPointSize ?? resolution.font.pointSize / max(multiplier, 0.01)
        markUnavailableNamedFace(resolution, for: geometry)
        var evidence = typefaceEvidence[identity] ?? TypefaceEvidence()
        let sample = Self.widthSample(of: geometry)
        if let sample {
            let resolverFamily = resolution.provenance == .hostSizeMatchedFamily ? resolution.font.familyName : nil
            Self.recordWidthSample(sample, in: &evidence, resolverFamily: resolverFamily, font: resolution.font, identity: identity)
        }
        if unavailableNamedFaceFields.contains(identity) {
            typefaceEvidence[identity] = evidence
            return Self.scaledSystemFace(size: size, evidence: evidence, sizeMultiplier: multiplier)
        }
        // A system face scaled to a width sample is scaled ONCE per field, to the first sample long
        // enough (`TypefaceEvidence.scalingAdoptionLength`): a sample that grows poll by poll (the
        // caret's own advance, `CaretAdvanceSampler`) would otherwise resize the ghost by a fraction
        // of a point on every presentation.
        // The adopted sample also outlives the caret sampler, which starts over at every line change
        // and edit: a presentation between two samples reached here as the unscaled reported size
        // and fell back to it (Claude's composer, 2026-09-10: the reported 14 for the painted 15.4,
        // 49 times in six minutes, each for the first dozen characters after a new line or edit).
        if resolution.provenance == .hostSizeScaledSystem || resolution.provenance == .hostSizeSystem,
           evidence.scalingSample != nil {
            typefaceEvidence[identity] = evidence
            let zoom = zoomStep(for: geometry)
            return Self.scaledSystemFace(
                size: size,
                evidence: evidence,
                reportedSize: zoom.reportedSize,
                zoomKind: zoom.kind,
                sizeMultiplier: multiplier
            )
        }
        guard let sample else {
            return resolution
        }
        // The system face is the first candidate: while it fits every sample, another family that
        // also fits is a coin flip on whole-point widths, not evidence (see `resolveBySize`).
        let systemFamily = NSFont.systemFont(ofSize: size).familyName ?? ""
        let verdict = evidence.verdict(candidates: [systemFamily] + GhostFontResolver.candidateFamilies) { family, sample in
            family == systemFamily
                ? GhostFontResolver.systemFaceFits(sample: sample.text, width: sample.width, size: size)
                : GhostFontResolver.familyFits(family, sample: sample.text, width: sample.width, size: size)
        }
        typefaceEvidence[identity] = evidence
        let hostFont: String = geometry.resolvedFieldStyle?.fontName ?? geometry.resolvedFieldStyle?.fontFamily ?? "-"
        let evidenceMetadata: Logger.Metadata = [
            "stage": .string("typeface-evidence"),
            "identity": .stringConvertible(identity),
            "sample": .string(String(sample.text.prefix(32))),
            "resolver_family": .string(resolution.font.familyName ?? "-"),
            "resolver_provenance": .string(resolution.provenance.rawValue),
            "host_font": .string(hostFont),
            "samples": .stringConvertible(evidence.samples.count),
            "adopted": .string(evidence.adoptedFamily ?? "-"),
            "verdict": .string("\(verdict)")
        ]
        CotabbyLogger.suggestion.debug("Typeface evidence", metadata: evidenceMetadata)
        return Self.settledResolution(
            for: verdict, replacing: resolution, systemFamily: systemFamily, size: size, evidence: evidence, sizeMultiplier: multiplier
        )
    }

    /// Marks a field whose face the ghost cannot load, which from then on takes the system face
    /// scaled to its own width (see `applyingTypefaceEvidence`).
    private func markUnavailableNamedFace(_ resolution: GhostFontResolver.Resolution, for geometry: SuggestionOverlayGeometry) {
        let identity = geometry.focusedInputIdentityKey
        if Self.hostNamesFace(geometry), resolution.provenance != .hostSizeMatchedFamily {
            unavailableNamedFaceFields.insert(identity)
        }
        // An Electron host that ships its editor's face (Claude's composer: Anthropic Sans) names
        // none, and no installed family is it: a width match at the reported size is a near miss
        // (Verdana at 14 fits Anthropic Sans at 15.4 within a percent) that flashed Verdana and
        // Georgia between samples (2026-09-10). Such a field takes the honest stand-in, the system
        // face scaled to its own width, until the pixel match names the bundled face.
        if geometry.isWebContentField, !BrowserAppDetector.isBrowser(bundleIdentifier: geometry.bundleIdentifier),
           !hostBundledFonts.candidateFontNames(forBundleIdentifier: geometry.bundleIdentifier).isEmpty {
            unavailableNamedFaceFields.insert(identity)
        }
    }

    /// Records a width sample in a field's evidence, logging the sample the evidence adopts when
    /// that changes.
    private static func recordWidthSample(
        _ sample: TypefaceEvidence.Sample,
        in evidence: inout TypefaceEvidence,
        resolverFamily: String?,
        font: NSFont,
        identity: UInt64
    ) {
        let adoptedBefore = evidence.scalingSample
        evidence.record(sample, resolverFamily: resolverFamily)
        if let adopted = evidence.scalingSample, adopted != adoptedBefore {
            logAdoptedWidthSample(adopted, font: font, identity: identity)
        }
    }

    /// The face a typeface verdict settles on, or `resolution` when it settles nothing new: the
    /// system face or a matched family replaces it, and an undecidable field takes the system face
    /// scaled to its own width.
    static func settledResolution(
        for verdict: TypefaceEvidence.Verdict,
        replacing resolution: GhostFontResolver.Resolution,
        systemFamily: String,
        size: CGFloat,
        evidence: TypefaceEvidence,
        sizeMultiplier: CGFloat = 1
    ) -> GhostFontResolver.Resolution {
        switch verdict {
        case .singleSample:
            return resolution
        case .family(let family) where family == systemFamily:
            guard resolution.font.familyName != systemFamily else { return resolution }
            return userScaled(
                GhostFontResolver.Resolution(font: NSFont.systemFont(ofSize: size), provenance: .hostSizeSystem, widthAgreement: 1),
                by: sizeMultiplier
            )
        case .family(let family):
            guard resolution.font.familyName != family, let font = GhostFontResolver.font(family: family, size: size) else {
                return resolution
            }
            return userScaled(
                GhostFontResolver.Resolution(font: font, provenance: .hostSizeMatchedFamily, widthAgreement: resolution.widthAgreement),
                by: sizeMultiplier
            )
        case .undecidable:
            return scaledSystemFace(size: size, evidence: evidence, sizeMultiplier: sizeMultiplier)
        }
    }

    /// One record per adopted sample: the text, the host's width of it, and what the current face
    /// makes of the same text, so a ghost sized from a bad sample can be traced to the sample.
    private static func logAdoptedWidthSample(_ sample: TypefaceEvidence.Sample, font: NSFont, identity: UInt64) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        let hostWidth = Double(sample.width)
        let fontSize = Double(font.pointSize)
        let fontWidth = Double(GhostFontResolver.width(of: sample.text, font: font))
        let metadata: Logger.Metadata = [
            "stage": .string("width-sample"),
            "identity": .stringConvertible(identity),
            "sample": .string(String(sample.text.prefix(40))),
            "chars": .stringConvertible(sample.text.count),
            "host_width": .stringConvertible(hostWidth),
            "font": .string(font.fontName),
            "font_size": .stringConvertible(fontSize),
            "font_width": .stringConvertible(fontWidth)
        ]
        CotabbyLogger.suggestion.debug("Width sample adopted", metadata: metadata)
    }

    /// The host's measured width sample for this geometry, when it has one.
    private static func widthSample(of geometry: SuggestionOverlayGeometry) -> TypefaceEvidence.Sample? {
        guard let text = geometry.hostTextMetrics?.sampleText, let width = geometry.hostTextMetrics?.sampleWidth, width > 0 else {
            return nil
        }
        return TypefaceEvidence.Sample(text: text, width: width)
    }

    /// The system face at the host's size, scaled to the field's adopted sample (the first one long
    /// enough, held for the field's life, see `TypefaceEvidence.scalingAdoptionLength`). Until one
    /// arrives the reported size is used as is: a size that followed every longer sample resized
    /// Gemini's ghost three times in one sentence.
    ///
    /// Where the host's face is judged to be the system face itself (`reportedSize` and `zoomKind`
    /// given), the host paints the reported size times a zoom step, and a scaled size within a
    /// percent of such a product is that product, as for a pixel match (`applyingMatchedTypeface`):
    /// a dozen-character sample of whole-point carets carries about half a percent, which showed as
    /// 15.06 between the reported 15.0 and the pixel match's 15.0 in a system-font Chrome field
    /// (three presentations, 2026-09-11). As a stand-in for another face (one the host names but
    /// this Mac lacks, or one no family fits) the scaled size is that face's advance, not a size the
    /// host set, and it is kept as the sample gives it.
    ///
    /// Every size here is the host's, measured from the host's own text, so the user's ghost size
    /// multiplier is applied last, as `GhostFontResolver.resolve` applies it to the resolution this
    /// replaces. Without it a field at a 60% multiplier rendered and remembered its ghost at the
    /// host's full size (15.7 where 9.4 was asked for in Claude's composer, 2026-10-29).
    static func scaledSystemFace(
        size: CGFloat,
        evidence: TypefaceEvidence,
        reportedSize: CGFloat? = nil,
        zoomKind: HostZoomLadder.Kind? = nil,
        sizeMultiplier: CGFloat = 1
    ) -> GhostFontResolver.Resolution {
        guard let sample = evidence.scalingSample else {
            return userScaled(
                GhostFontResolver.Resolution(font: NSFont.systemFont(ofSize: size), provenance: .hostSizeSystem, widthAgreement: 1),
                by: sizeMultiplier
            )
        }
        let scaled = GhostFontResolver.scaledSystemResolution(size: size, sample: sample.text, width: sample.width)
        guard let reportedSize, let zoomKind,
              let snapped = HostZoomLadder.snappedSize(measured: scaled.font.pointSize, reported: reportedSize, kind: zoomKind),
              snapped != scaled.font.pointSize
        else {
            return userScaled(scaled, by: sizeMultiplier)
        }
        let font = GhostFontResolver.resized(scaled.font, to: snapped)
        let measured = GhostFontResolver.width(of: sample.text, font: font)
        return userScaled(
            GhostFontResolver.Resolution(
                font: font, provenance: .hostSizeScaledSystem, widthAgreement: measured > 0 ? sample.width / measured : 1
            ),
            by: sizeMultiplier
        )
    }

    /// A resolution at the host's size, resized by the user's ghost size multiplier. The width
    /// agreement is the host-size face's, as in `GhostFontResolver.resolve`.
    static func userScaled(_ resolution: GhostFontResolver.Resolution, by sizeMultiplier: CGFloat) -> GhostFontResolver.Resolution {
        guard sizeMultiplier > 0, abs(sizeMultiplier - 1) > 0.001 else { return resolution }
        return GhostFontResolver.Resolution(
            font: GhostFontResolver.resized(resolution.font, to: resolution.font.pointSize * sizeMultiplier),
            provenance: resolution.provenance,
            widthAgreement: resolution.widthAgreement
        )
    }

    /// The face and size the host's pixels matched replace a stand-in face, and a width-matched
    /// family too: a strip of glyph shapes is stronger evidence than one or two whole-point width
    /// samples (measured 2026-09-10: Chrome's Helvetica input width-matched Trebuchet MS for 108
    /// presentations between pixel matches of Arial and Helvetica Neue). A face the host named is
    /// never replaced, even one this Mac cannot load: the scaled system face is the honest stand-in
    /// there (Gemini's Google Sans), and a near miss from the candidate list would look worse.
    ///
    /// A match must also agree with the width the host itself rendered, when one was measured: the
    /// advance is the host's own metric, and a face whose advance of the sample text is off by more
    /// than `matchedAdvanceTolerance` is at the wrong size whatever its shapes scored (Claude's
    /// composer, 2026-09-10: the system face at 16.15 scored 0.89 on Anthropic Sans set at 15.4,
    /// five percent wider than the caret's own travel). Within that tolerance the pixels name the
    /// face and the sample sets its size: a web engine renders a face without the tracking
    /// CoreText applies (Obsidian's system face at 16 advanced 1.5% less than CoreText's), and a
    /// ghost whose advances are the host's lands every typed-through and accepted word where the
    /// host puts it, at a glyph size a fraction of a pixel off.
    ///
    /// A web host paints its reported CSS size (`reportedSize`) times a factor from its zoom ladder
    /// (`zoomKind`), and a matched size within a percent of such a product is that product (see
    /// `HostZoomLadder`): the fit wanders by about half a percent between fields, and Obsidian's
    /// 16px text matched at 16.10 drifted two device pixels by a line's end where 15.99 held every
    /// word within one (2026-09-11).
    static func applyingMatchedTypeface(
        _ resolution: GhostFontResolver.Resolution,
        match: HostBaselineCalibrator.TypefaceMatchRecord?,
        hostNamesFace: Bool,
        widthSample: TypefaceEvidence.Sample? = nil,
        sizeMultiplier: CGFloat,
        reportedSize: CGFloat? = nil,
        zoomKind: HostZoomLadder.Kind? = nil
    ) -> GhostFontResolver.Resolution {
        func onLadder(_ size: CGFloat) -> CGFloat {
            guard let reportedSize, let zoomKind else { return size }
            return HostZoomLadder.snappedSize(measured: size, reported: reportedSize, kind: zoomKind) ?? size
        }
        guard let match, !hostNamesFace, Self.acceptsPixelMatch(resolution.provenance),
              let unscaled = GhostFontResolver.font(named: match.fontName, size: match.pointSize),
              let matched = GhostFontResolver.font(named: match.fontName, size: onLadder(match.pointSize) * max(sizeMultiplier, 0.01))
        else {
            return resolution
        }
        // A settled match (`HostBaselineCalibrator.settledTypefaceScore`) is the host's face at
        // the host's size to within a few hundredths of a point (the correlation falls off a fifth
        // of the scale a sixth of a point away): it keeps its own size and needs no sample's
        // agreement. Measured 2026-09-10 in Chrome's contenteditable: a first twelve-character
        // caret sample one advance short refused the system face matched at 15.05 with 0.96 and
        // left the ghost at 13.7 for the field's life.
        if let widthSample, widthSample.width > 0, !widthSample.text.isEmpty,
           match.score < HostBaselineCalibrator.settledTypefaceScore {
            let advance = GhostFontResolver.width(of: widthSample.text, font: unscaled)
            guard advance > 0, abs(advance / widthSample.width - 1) <= Self.matchedAdvanceTolerance else {
                return resolution
            }
            let fitted = GhostFontResolver.scaled(unscaled, toSample: widthSample.text, width: widthSample.width)
            let sized = GhostFontResolver.resized(fitted, to: onLadder(fitted.pointSize) * max(sizeMultiplier, 0.01))
            return GhostFontResolver.Resolution(font: sized, provenance: .pixelMatched, widthAgreement: 1)
        }
        return GhostFontResolver.Resolution(font: matched, provenance: .pixelMatched, widthAgreement: 1)
    }

    /// Relative disagreement between a pixel-matched face's advance and the host's measured
    /// sample above which the match is not this text's size. A twelve-character sample of
    /// whole-pixel caret positions carries about a percent of rounding.
    static let matchedAdvanceTolerance: CGFloat = 0.02

    /// Provenances the pixel match outranks: every stand-in, a width-matched family, and an
    /// earlier pixel match (the field's record may have improved).
    static func acceptsPixelMatch(_ provenance: GhostFontResolver.Provenance) -> Bool {
        provenance.isFallbackFace || provenance == .hostSizeMatchedFamily || provenance == .pixelMatched
    }

    private func typefaceKey(for geometry: SuggestionOverlayGeometry) -> HostBaselineCalibrator.TypefaceKey {
        HostBaselineCalibrator.TypefaceKey(focusedInputIdentityKey: geometry.focusedInputIdentityKey)
    }

    /// Whether the resolution's size came from the host (a plausible reported size, possibly
    /// scaled to a width sample) rather than from the caret box.
    static func sizeIsReported(_ provenance: GhostFontResolver.Provenance) -> Bool {
        switch provenance {
        case .hostFace, .hostFamily, .hostSizeMatchedFamily, .hostSizeScaledSystem, .hostSizeSystem, .hostFaceScaled, .pixelMatched,
             .hostRemembered, .hostAdvanceFitted:
            return true
        case .caretDerived, .caretDerivedCalibrated:
            return false
        }
    }

    /// Whether the resolution's size was scaled to a width the host rendered (a bounds query or
    /// the caret's own advance), which pins it within a couple of percent whatever the host said.
    static func sizeIsMeasured(_ provenance: GhostFontResolver.Provenance) -> Bool {
        switch provenance {
        case .hostSizeScaledSystem, .hostFaceScaled, .caretDerivedCalibrated, .hostAdvanceFitted:
            return true
        case .hostFace, .hostFamily, .hostSizeMatchedFamily, .hostSizeSystem, .pixelMatched, .caretDerived, .hostRemembered:
            return false
        }
    }

    // MARK: - Line pitch and the card's size

    /// Vertical distance between the host's lines: measured when the host let us (line APIs, a
    /// character-bounds scan, sibling text runs), else the caret box height. For a TextKit host the
    /// caret box IS the line fragment, so that is exact; for a web engine it is the content box and
    /// can be a pixel short of the line box (Chrome: 15 or 16 for a 16.25 pitch), which matters
    /// only until the field has a second line to measure. A row placed a pixel off beats the card:
    /// measured live, the card at the end of a first line was the single most disliked behavior.
    ///
    /// A pitch no text of the ghost's size can have (`HostFaceMemory.isPlausiblePitch`) is a misread
    /// and is neither used nor remembered: Obsidian's one-line runs three lines apart once gave 72pt
    /// for 16pt text, and a capital alone on a fresh line in Claude gave 12.5pt for 15.3pt.
    func linePitch(for geometry: SuggestionOverlayGeometry, fontSize: CGFloat) -> CGFloat? {
        let key = geometry.isWebContentField ? hostStyleKey(for: geometry) : nil
        // The ghost's size carries the user's multiplier; the host's line-height does not.
        let hostSize = fontSize / flooredSizeMultiplier
        if let measured = geometry.hostTextMetrics?.linePitch, measured > 0,
           HostFaceMemory.isPlausiblePitch(measured, pointSize: hostSize) {
            if geometry.hostTextMetrics?.linePitchIsFromParagraphBox == true {
                let remembered = key.flatMap { hostFaceMemory.pitch(for: $0) }
                    .flatMap { HostFaceMemory.isPlausiblePitch($0, pointSize: hostSize) ? $0 : nil }
                return Self.pitch(fromParagraphBox: measured, remembered: remembered)
            }
            if let key {
                if hostFaceMemory.recordPitch(measured, for: key) {
                    saveFaceMemory()
                }
            }
            return measured
        }
        guard geometry.caretRect.height > 0, geometry.caretQuality != .estimated else {
            return nil
        }
        // A web engine's caret box is the glyph box, shorter than the line (Claude's composer: 19
        // for 22); a field of the same style that did measure its pitch knows the line-height.
        if let key, let remembered = hostFaceMemory.pitch(for: key),
           HostFaceMemory.isPlausiblePitch(remembered, pointSize: hostSize) {
            return remembered
        }
        return geometry.caretRect.height
    }

    /// Points a remembered pitch may differ from a paragraph's box and still describe the same lines:
    /// Chromium rounds the box out to whole points (24 for a 23.1pt line at 110%, 2026-09-11).
    static let paragraphBoxPitchSlack: CGFloat = 1.5

    /// The pitch for a paragraph's first line when the host gave only the paragraph's box: the pitch
    /// this host style measured between two lines, when one is remembered and agrees with the box to
    /// within its rounding, else the box. In a ProseMirror-style page at 110% the box read 24 where two
    /// lines had measured 23.5 for the true 23.1, and every first wrap after the first sat a point
    /// low. A remembered pitch further from the box belongs to another line-height of the same size
    /// and page (a double-spaced text area beside a chat box) and does not replace it.
    static func pitch(fromParagraphBox box: CGFloat, remembered: CGFloat?) -> CGFloat {
        guard let remembered, abs(remembered - box) <= paragraphBoxPitchSlack else { return box }
        return remembered
    }

    /// The host's own text size for the mirror card under Match Original Text Size: the size the
    /// field reports, else one the inline path measured for this field (an advance fit, or a face
    /// remembered with its advance measured). Never the caret height: an untrustworthy caret is
    /// often why the card is showing at all. Nil keeps the card's fixed size.
    func mirrorHostFontSize(for geometry: SuggestionOverlayGeometry) -> CGFloat? {
        guard suggestionSettings.matchesHostTextSize else { return nil }
        if let reported = geometry.resolvedFieldStyle?.fontPointSize, reported > 0 { return reported }
        if let adopted = hostAdvanceFits[geometry.focusedInputIdentityKey]?.adopted { return adopted.pointSize }
        // Remembered with the multiplier applied; matching the host size makes that multiplier 1.
        if let key = hostStyleKey(for: geometry), let remembered = hostFaceMemory.face(for: key),
           remembered.advanceMeasured == true {
            return remembered.pointSize
        }
        return nil
    }
}
