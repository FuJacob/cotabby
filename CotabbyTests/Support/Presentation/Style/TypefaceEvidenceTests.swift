import XCTest
@testable import Cotabby

/// Numbers from the Gemini prompt bar, where six samples of one field fitted four different faces
/// in turn. `fits` below reproduces which family each real sample admitted at a 2% tolerance.
final class TypefaceEvidenceTests: XCTestCase {
    private typealias Sample = TypefaceEvidence.Sample
    private let candidates = ["Helvetica", "Georgia", "Trebuchet MS", "Tahoma"]

    /// Per-sample fits measured with CoreText against the host widths Gemini reported.
    private func gemini(_ family: String, _ sample: Sample) -> Bool {
        switch sample.text {
        case "ask me about the", "ask me about the weat": return family == "Georgia"
        case "e about the weather in Toronto t": return family == "Helvetica"
        case "and": return family == "Tahoma" || family == "Trebuchet MS"
        default: return false
        }
    }

    func testOneSampleLeavesTheResolverDecisionAlone() {
        var evidence = TypefaceEvidence()
        evidence.record(Sample(text: "ask me about the", width: 127.2), resolverFamily: "Georgia")
        XCTAssertEqual(evidence.verdict(candidates: candidates, fits: gemini), .singleSample)
    }

    func testASecondSampleThatStillFitsKeepsTheAdoptedFamily() {
        var evidence = TypefaceEvidence()
        evidence.record(Sample(text: "ask me about the", width: 127.2), resolverFamily: "Georgia")
        evidence.record(Sample(text: "ask me about the weat", width: 166.9), resolverFamily: "Georgia")
        XCTAssertEqual(evidence.verdict(candidates: candidates, fits: gemini), .family("Georgia"))
    }

    /// The Gemini sequence: Georgia is adopted, a longer sample rules it out, and since Helvetica
    /// fails the earlier samples no family fits everything, so the field settles on the scaled
    /// system face and never changes again. Today's code flipped Georgia -> Helvetica -> Trebuchet.
    func testContradictorySamplesSettleOnUndecidableForGood() {
        var evidence = TypefaceEvidence()
        evidence.record(Sample(text: "ask me about the", width: 127.2), resolverFamily: "Georgia")
        evidence.record(Sample(text: "ask me about the weat", width: 166.9), resolverFamily: "Georgia")
        evidence.record(Sample(text: "e about the weather in Toronto t", width: 235.9), resolverFamily: "Helvetica")
        XCTAssertEqual(evidence.verdict(candidates: candidates, fits: gemini), .undecidable)
        evidence.record(Sample(text: "and", width: 27.8), resolverFamily: "Trebuchet MS")
        XCTAssertEqual(evidence.verdict(candidates: candidates, fits: gemini), .undecidable, "undecidable is final")
    }

    func testShortSamplesNeverDecide() {
        var evidence = TypefaceEvidence()
        evidence.record(Sample(text: "ask me about the", width: 127.2), resolverFamily: "Georgia")
        evidence.record(Sample(text: "and", width: 27.8), resolverFamily: "Tahoma")
        XCTAssertEqual(evidence.verdict(candidates: candidates, fits: gemini), .family("Georgia"))
    }

    /// A first sample that fitted the wrong face by coincidence is corrected once, to the one
    /// family that fits everything, and stays there.
    func testSwitchesOnceToTheOnlyFamilyFittingEverySample() {
        var evidence = TypefaceEvidence()
        evidence.record(Sample(text: "delta echo fox", width: 100), resolverFamily: "Georgia")
        evidence.record(Sample(text: "delta echo foxtrot golf hotel", width: 200), resolverFamily: "Helvetica")
        let fits: (String, Sample) -> Bool = { family, sample in
            switch sample.text {
            case "delta echo fox": return family == "Georgia" || family == "Helvetica"
            case "delta echo foxtrot golf hotel": return family == "Helvetica"
            default: return family == "Georgia"   // the third sample contradicts the switched-to face
            }
        }
        XCTAssertEqual(evidence.verdict(candidates: candidates, fits: fits), .family("Helvetica"))
        XCTAssertTrue(evidence.hasSwitched)
        evidence.record(Sample(text: "delta echo foxtrot golf hotel india", width: 260), resolverFamily: "Georgia")
        XCTAssertEqual(
            evidence.verdict(candidates: candidates, fits: fits), .undecidable,
            "a second contradiction ends in the neutral face, not another switch"
        )
    }

    /// Measured in Gemini: scaling to the longest sample so far resized the ghost three times in
    /// one sentence. The first sample of a dozen characters sizes the field for good.
    func testTheFirstLongSampleFixesTheScalingSampleUntilOneTwiceAsLongRefinesItOnce() {
        var evidence = TypefaceEvidence()
        evidence.record(.init(text: "ask me", width: 48), resolverFamily: nil)
        XCTAssertNil(evidence.scalingSample)
        evidence.record(.init(text: "ask me about the", width: 120), resolverFamily: nil)
        XCTAssertEqual(evidence.scalingSample?.text, "ask me about the")
        evidence.record(.init(text: "ask me about the weather", width: 180), resolverFamily: nil)
        XCTAssertEqual(evidence.scalingSample?.text, "ask me about the", "a merely longer sample never re-sizes the field")
        // Twice the adopted length halves the rounding of a caret-measured sample: one refinement.
        evidence.record(.init(text: "ask me about the weather in Toronto t", width: 290), resolverFamily: nil)
        XCTAssertEqual(evidence.scalingSample?.text, "ask me about the weather in Toronto t")
        evidence.record(.init(text: String(repeating: "ask me about the weather in Toronto today ", count: 3), width: 900), resolverFamily: nil)
        XCTAssertEqual(evidence.scalingSample?.text, "ask me about the weather in Toronto t", "the refinement happens once")
    }

    /// With the system face first among the candidates, a second family that also fits every sample
    /// leaves the verdict undecided instead of electing that family.
    func testAFamilyThatOnlyMatchesTheSystemFaceIsNotElected() {
        var evidence = TypefaceEvidence()
        evidence.record(.init(text: "the first sample text", width: 100), resolverFamily: nil)
        evidence.record(.init(text: "another longer sample", width: 110), resolverFamily: nil)
        let verdict = evidence.verdict(candidates: ["System", "Trebuchet MS"]) { _, _ in true }
        XCTAssertEqual(verdict, .undecidable)
    }
}
