import AppKit

/// File overview:
/// What a field's accumulated width samples say about its typeface, for hosts that name no face.
///
/// `GhostFontResolver` picks a family by comparing ONE measured width against candidate faces.
/// That is the right call for a field measured once, which is nearly every field. It goes wrong
/// in a field the host keeps re-measuring as it grows, because a single sample cannot tell a
/// coincidental fit from the real face. Measured in Gemini's prompt bar: six samples of one field
/// fitted Georgia, Georgia, Helvetica and Trebuchet in turn (per-character widths swung from 7.4
/// to 9.3pt, which no one font produces), and the ghost changed typeface four times in a sentence.
///
/// Rule, applied only once a field has produced a second, different sample:
///   - the family adopted from the first sample is kept while every later long sample still fits it;
///   - a long sample it fails switches the field to a family that fits ALL long samples, if there is
///     exactly such a family, at most once;
///   - if no family fits every long sample, the field is undecidable and settles on the system
///     face scaled to the latest sample, for the rest of the field's life.
/// Short samples (under `minimumEvidenceLength`) are recorded but never decide: three characters
/// of whole-point-rounded width carry more noise than the gap between families.
///
/// Pure value type owned per field by `OverlayController`; nothing here touches AX or the screen.
struct TypefaceEvidence: Equatable {
    struct Sample: Equatable {
        let text: String
        let width: CGFloat
    }

    enum Verdict: Equatable {
        /// Fewer than two distinct samples: the resolver's own single-sample decision stands.
        case singleSample
        /// Keep rendering in this family.
        case family(String)
        /// No family fits every long sample: use the system face scaled to the latest sample.
        case undecidable
    }

    static let minimumEvidenceLength = 8
    /// Shortest sample worth scaling the system face to; below it, rounding noise outweighs the
    /// scale it would set.
    static let minimumScalingLength = 6
    /// The first sample at least this long fixes the scaled system face's size for the field's
    /// life. Measured 2026-09-10 in Gemini's prompt bar: scaling to the longest sample so far
    /// resized the ghost three times in one sentence (17 → 15.87 → 15.94 → 16.24) as longer samples
    /// arrived; one adoption from a dozen characters is within the samples' own noise and never
    /// moves text already on screen.
    static let scalingAdoptionLength = 12
    static let maximumSamples = 8

    private(set) var samples: [Sample] = []
    private(set) var adoptedFamily: String?
    private(set) var hasSwitched = false
    private(set) var isUndecidable = false
    /// The sample the scaled system face is sized from, once one long enough has arrived.
    private(set) var scalingSample: Sample?

    /// Records a sample (deduplicated by text) and the family the resolver chose from it alone.
    mutating func record(_ sample: Sample, resolverFamily: String?) {
        if !samples.contains(where: { $0.text == sample.text }) {
            samples.append(sample)
            if samples.count > Self.maximumSamples {
                samples.removeFirst()
            }
        }
        if scalingSample == nil, sample.text.count >= Self.scalingAdoptionLength, sample.width > 0 {
            scalingSample = sample
        }
        if adoptedFamily == nil, samples.count == 1 {
            adoptedFamily = resolverFamily
        }
    }

    /// The family to render with, judged against every long sample recorded so far.
    /// `fits` says whether a family reproduces one sample's width within tolerance.
    mutating func verdict(candidates: [String], fits: (String, Sample) -> Bool) -> Verdict {
        guard samples.count >= 2 else { return .singleSample }
        if isUndecidable { return .undecidable }
        let evidence = samples.filter { $0.text.count >= Self.minimumEvidenceLength }
        guard !evidence.isEmpty else { return adoptedFamily.map(Verdict.family) ?? .singleSample }
        if let adopted = adoptedFamily, evidence.allSatisfy({ fits(adopted, $0) }) {
            return .family(adopted)
        }
        let fitting = candidates.filter { family in evidence.allSatisfy { fits(family, $0) } }
        if !hasSwitched, fitting.count == 1, let only = fitting.first {
            adoptedFamily = only
            hasSwitched = true
            return .family(only)
        }
        if let adopted = adoptedFamily, hasSwitched, fitting.contains(adopted) {
            return .family(adopted)
        }
        isUndecidable = true
        return .undecidable
    }
}
