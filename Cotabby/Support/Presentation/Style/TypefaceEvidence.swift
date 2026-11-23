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
///   - a long sample it fails switches the field, at most once, to a family that fits ALL long
///     samples, the earliest candidate when several do (they then share the face's advances);
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
    /// The first sample at least this long fixes the scaled system face's size for the field's
    /// life. Measured 2026-09-10 in Gemini's prompt bar: scaling to the longest sample so far
    /// resized the ghost three times in one sentence (17 → 15.87 → 15.94 → 16.24) as longer samples
    /// arrived; one adoption from a dozen characters is within the samples' own noise and never
    /// moves text already on screen. One refinement is allowed, from a sample at least
    /// `scalingRefinementFactor` times longer: a dozen characters of whole-pixel caret positions
    /// carry a percent of rounding that two dozen halve, and a single small step beats holding a
    /// short sample's error for the field's life.
    static let scalingAdoptionLength = 12
    static let scalingRefinementFactor = 2
    static let maximumSamples = 8

    /// Which family the field renders in, and how it came to. Each step is taken at most once and
    /// never back, which is what keeps a field from changing face more than once in its life.
    private enum FamilyDecision: Equatable {
        /// Nothing adopted yet: no sample, or a first sample the resolver matched no family to.
        case pending
        /// The family the resolver chose from the first sample alone.
        case resolverChoice(String)
        /// The one correction: a family that fitted every long sample when the earlier one failed.
        case switched(String)
        /// No family fitted every long sample, for good. Carries the family the field last rendered
        /// in, which diagnostics still report.
        case undecidable(last: String?)

        var family: String? {
            switch self {
            case .pending: return nil
            case .resolverChoice(let family), .switched(let family): return family
            case .undecidable(let last): return last
            }
        }
    }

    /// Which sample the scaled system face is sized from: none until one long enough arrives, then
    /// that one, then at most one refinement.
    private enum ScalingAdoption: Equatable {
        case none
        case adopted(Sample)
        case refined(Sample)
    }

    private(set) var samples: [Sample] = []
    private var familyDecision = FamilyDecision.pending
    private var scalingAdoption = ScalingAdoption.none

    /// The family the field has adopted, if any (for diagnostics; `verdict` is the decision).
    var adoptedFamily: String? { familyDecision.family }

    /// The sample the scaled system face is sized from, once one long enough has arrived.
    var scalingSample: Sample? {
        switch scalingAdoption {
        case .none: return nil
        case .adopted(let sample), .refined(let sample): return sample
        }
    }

    /// Records a sample (deduplicated by text) and the family the resolver chose from it alone.
    mutating func record(_ sample: Sample, resolverFamily: String?) {
        if !samples.contains(where: { $0.text == sample.text }) {
            samples.append(sample)
            if samples.count > Self.maximumSamples {
                samples.removeFirst()
            }
        }
        if sample.width > 0 {
            switch scalingAdoption {
            case .none:
                if sample.text.count >= Self.scalingAdoptionLength {
                    scalingAdoption = .adopted(sample)
                }
            case .adopted(let adopted):
                if sample.text.count >= adopted.text.count * Self.scalingRefinementFactor {
                    scalingAdoption = .refined(sample)
                }
            case .refined:
                break
            }
        }
        if familyDecision == .pending, samples.count == 1, let resolverFamily {
            familyDecision = .resolverChoice(resolverFamily)
        }
    }

    /// The family to render with, judged against every long sample recorded so far.
    /// `fits` says whether a family reproduces one sample's width within tolerance.
    mutating func verdict(candidates: [String], fits: (String, Sample) -> Bool) -> Verdict {
        guard samples.count >= 2 else { return .singleSample }
        if case .undecidable = familyDecision { return .undecidable }
        let evidence = samples.filter { $0.text.count >= Self.minimumEvidenceLength }
        guard !evidence.isEmpty else { return adoptedFamily.map(Verdict.family) ?? .singleSample }
        if let adopted = adoptedFamily, evidence.allSatisfy({ fits(adopted, $0) }) {
            return .family(adopted)
        }
        // The adopted family, if there is one, has now failed a long sample. A field that has not
        // switched yet moves, once, to a family that fits every long sample. Those are all the
        // face's advances; the candidates' own order (how often each is the real answer) breaks the
        // tie. Demanding exactly one left a Menlo textarea undecidable, Courier New fitting its
        // samples as well as Menlo, and it settled on the proportional system face scaled to
        // monospace widths, 13pt text as 17.2 (Chrome, 2026-09-11).
        switch familyDecision {
        case .pending, .resolverChoice:
            if let first = candidates.first(where: { family in evidence.allSatisfy { fits(family, $0) } }) {
                familyDecision = .switched(first)
                return .family(first)
            }
        case .switched, .undecidable:
            break
        }
        familyDecision = .undecidable(last: adoptedFamily)
        return .undecidable
    }
}
