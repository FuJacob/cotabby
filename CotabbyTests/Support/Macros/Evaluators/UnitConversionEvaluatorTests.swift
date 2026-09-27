import XCTest
@testable import Cotabby

/// Tests for the offline physical-unit conversion macros (`/10km->mi`, `/100 f to c`).
///
/// Results are formatted as an integer when exact, otherwise to four significant digits, and are
/// labelled with the target token exactly as the user typed it (lowercased). Cross-quantity requests
/// must return nil so the currency family gets the same `->` string next.
final class UnitConversionEvaluatorTests: XCTestCase {
    private let sut = UnitConversionEvaluator(locale: Locale(identifier: "en_US"))

    // MARK: - Each quantity

    func test_convertsWithinEachQuantity() {
        let cases: [(query: String, expected: String)] = [
            ("10km->mi", "6.214 mi"),          // length, non-integer result
            ("1km->m", "1000 m"),              // length, integer result has no decimals
            ("5ft->in", "60 in"),
            ("1kg->g", "1000 g"),              // mass
            ("1 pound to kg", "0.4536 kg"),
            ("100f->c", "37.78 c"),            // temperature (affine, not just a scale)
            ("-40c->f", "-40 f"),              // the one point where both scales agree
            ("1l->ml", "1000 ml"),             // volume
            ("1floz->ml", "29.57 ml")
        ]
        for (query, expected) in cases {
            XCTAssertEqual(sut.evaluate(query)?.insertionText, expected, query)
        }
    }

    func test_previewMatchesInsertion() {
        XCTAssertEqual(sut.evaluate("1km->m"), MacroResult("1000 m"))
    }

    // MARK: - Separators and token spelling

    func test_everySeparatorParsesIdentically() {
        for query in ["10km->mi", "10km→mi", "10 km to mi", "10 KM TO MI", "10 km -> mi"] {
            XCTAssertEqual(sut.evaluate(query)?.insertionText, "6.214 mi", query)
        }
    }

    func test_fullAndBritishUnitNames_areAccepted() {
        XCTAssertEqual(sut.evaluate("1 kilometer to meters")?.insertionText, "1000 meters")
        XCTAssertEqual(sut.evaluate("1 kilometre to metres")?.insertionText, "1000 metres")
        XCTAssertEqual(sut.evaluate("100 fahrenheit to celsius")?.insertionText, "37.78 celsius")
    }

    // MARK: - Rejections

    func test_crossQuantity_returnsNil() {
        XCTAssertNil(sut.evaluate("10km->kg"))
        XCTAssertNil(sut.evaluate("5c->ml"))
    }

    func test_ozIsMassSoFluidVolumeTargetIsCrossQuantity() {
        // `oz` deliberately means ounce-mass; `floz` is the fluid ounce. Converting `oz` to a volume
        // must refuse rather than silently treat it as fluid ounces.
        XCTAssertNil(sut.evaluate("1oz->ml"))
        XCTAssertNotNil(sut.evaluate("1oz->g"))
    }

    func test_unknownTokens_returnNil() {
        XCTAssertNil(sut.evaluate("100USD->EUR"))
        XCTAssertNil(sut.evaluate("10min->s"))
    }

    func test_missingNumberOrToken_returnsNil() {
        XCTAssertNil(sut.evaluate("km->mi"))
        XCTAssertNil(sut.evaluate("10->mi"))
        XCTAssertNil(sut.evaluate("10km->"))
    }

    func test_queryWithoutSeparator_returnsNil() {
        XCTAssertNil(sut.evaluate("10km mi"))
    }
}
