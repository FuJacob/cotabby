import XCTest
@testable import Cotabby

final class CaretSourceDetailTests: XCTestCase {
    /// The raw values appear in the debug caret badge and in the logs' `caret_source`; anything
    /// that filters on them breaks if one is renamed.
    func test_rawValuesAreTheLabelsShownInTheCaretSource() {
        let labels: [CaretSourceDetail: String] = [
            .previousCharacter: "previous-character",
            .textMarker: "text-marker",
            .zeroLength: "zero-length",
            .zeroLengthWithLine: "zero-length+line",
            .zeroLengthAfterBreak: "zero-length-after-break",
            .wrappedRun: "wrapped-run",
            .wrappedRunCharacterBounds: "wrapped-run-character-bounds",
            .runsAligned: "runs-aligned",
            .runsPartiallyAligned: "runs-partial",
            .runsLegacyCumulative: "runs-legacy"
        ]

        XCTAssertEqual(Set(labels.keys), Set(CaretSourceDetail.allCases))
        for (detail, label) in labels {
            XCTAssertEqual(detail.rawValue, label)
        }
    }

    func test_onlyTheRunMappingsAreRunProportional() {
        let proportional = CaretSourceDetail.allCases.filter(\.isRunProportional)

        XCTAssertEqual(Set(proportional), [.runsAligned, .runsPartiallyAligned, .runsLegacyCumulative])
    }

    @MainActor
    func test_everyRunMappingModeHasARunProportionalDetail() {
        let modes: [AXTextGeometryResolver.CaretRunMappingMode] = [.aligned, .partiallyAligned, .legacyCumulative]

        XCTAssertEqual(modes.map { $0.sourceDetail }, [.runsAligned, .runsPartiallyAligned, .runsLegacyCumulative])
    }
}
