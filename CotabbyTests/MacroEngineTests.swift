import XCTest
@testable import Cotabby

/// Tests for the random, unit-conversion, and currency macro evaluators, plus the engine that routes
/// a query to the first matching family.

final class RandomMacroEvaluatorTests: XCTestCase {
    /// A deterministic evaluator: the RNG always returns the low end of the range, and the UUID is fixed.
    private let sut = RandomMacroEvaluator(randomSource: { $0.lowerBound }, uuidSource: { "FIXED-UUID" })

    func test_randomRange() {
        XCTAssertEqual(sut.evaluate("random(1,2)")?.insertionText, "1")
    }

    func test_randomSingleArgument() {
        XCTAssertEqual(sut.evaluate("random(5)")?.insertionText, "1")
    }

    func test_randomDefaultRange() {
        XCTAssertEqual(sut.evaluate("random")?.insertionText, "0")
    }

    func test_randomNormalizesReversedBounds() {
        XCTAssertEqual(sut.evaluate("random(2,1)")?.insertionText, "1")
    }

    func test_dice() {
        XCTAssertEqual(sut.evaluate("dice")?.insertionText, "1")
    }

    func test_coin() {
        XCTAssertEqual(sut.evaluate("coin")?.insertionText, "Heads")
    }

    func test_uuid() {
        XCTAssertEqual(sut.evaluate("uuid")?.insertionText, "FIXED-UUID")
    }

    func test_invalidArguments_returnNil() {
        XCTAssertNil(sut.evaluate("random(abc)"))
        XCTAssertNil(sut.evaluate("random(0)"))
    }

    func test_aliasesAndDiceNotation() {
        XCTAssertEqual(sut.evaluate("rand")?.insertionText, "0")
        XCTAssertEqual(sut.evaluate("roll")?.insertionText, "1")
        XCTAssertEqual(sut.evaluate("flip")?.insertionText, "Heads")
        XCTAssertEqual(sut.evaluate("guid")?.insertionText, "FIXED-UUID")
        XCTAssertEqual(sut.evaluate("d20")?.insertionText, "1")
        XCTAssertEqual(sut.evaluate("rnd(7,7)")?.insertionText, "7")
    }
}

final class UnitConversionEvaluatorTests: XCTestCase {
    private let sut = UnitConversionEvaluator(locale: Locale(identifier: "en_US"))

    func test_lengthKilometersToMiles() {
        XCTAssertEqual(sut.evaluate("10km->mi")?.insertionText, "6.214 mi")
    }

    func test_temperatureFahrenheitToCelsius() {
        XCTAssertEqual(sut.evaluate("100f->c")?.insertionText, "37.78 c")
    }

    func test_integerResultHasNoDecimals() {
        XCTAssertEqual(sut.evaluate("1km->m")?.insertionText, "1000 m")
        XCTAssertEqual(sut.evaluate("5ft->in")?.insertionText, "60 in")
    }

    func test_crossQuantity_returnsNil() {
        XCTAssertNil(sut.evaluate("10km->kg"))
    }

    func test_nonUnitTokens_returnNil() {
        XCTAssertNil(sut.evaluate("100USD->EUR"))
    }

    func test_toSeparatorAndFullNames() {
        XCTAssertEqual(sut.evaluate("10 km to mi")?.insertionText, "6.214 mi")
        XCTAssertEqual(sut.evaluate("1 kilometer to meters")?.insertionText, "1000 meters")
        XCTAssertEqual(sut.evaluate("100 fahrenheit to celsius")?.insertionText, "37.78 celsius")
    }
}

final class CurrencyEvaluatorTests: XCTestCase {
    private let sut = CurrencyEvaluator(locale: Locale(identifier: "en_US"))

    func test_sameCurrency() {
        XCTAssertEqual(sut.evaluate("100USD->USD")?.insertionText, "$100.00")
    }

    func test_crossRateViaUSD() {
        // 136 CAD / 1.36 (CAD per USD) = 100 USD.
        XCTAssertEqual(sut.evaluate("136CAD->USD")?.insertionText, "$100.00")
    }

    func test_targetCurrencyFormatting() {
        let result = sut.evaluate("100USD->EUR")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.insertionText.contains("92") ?? false)
    }

    func test_unknownCode_returnsNil() {
        XCTAssertNil(sut.evaluate("100XXX->USD"))
    }

    func test_aliasesSymbolsAndToSeparator() {
        let canonical = sut.evaluate("100USD->EUR")?.insertionText
        XCTAssertEqual(sut.evaluate("100us->eur")?.insertionText, canonical)
        XCTAssertEqual(sut.evaluate("$100 to eur")?.insertionText, canonical)
        XCTAssertEqual(sut.evaluate("100 dollars to euros")?.insertionText, canonical)
    }
}

final class MacroEngineRoutingTests: XCTestCase {
    private func makeEngine() -> MacroEngine {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 12))!
        return MacroEngine.standard(
            now: { now },
            calendar: calendar,
            locale: Locale(identifier: "en_US"),
            randomSource: { $0.lowerBound }
        )
    }

    func test_routesToEachFamily() {
        let engine = makeEngine()
        XCTAssertEqual(engine.evaluate("today")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(engine.evaluate("5+5")?.previewText, "= 10")
        XCTAssertEqual(engine.evaluate("10km->mi")?.insertionText, "6.214 mi")
        XCTAssertEqual(engine.evaluate("136CAD->USD")?.insertionText, "$100.00")
        XCTAssertEqual(engine.evaluate("random(7,7)")?.insertionText, "7")
    }

    func test_emptyAndUnknownReturnNil() {
        let engine = makeEngine()
        XCTAssertNil(engine.evaluate(""))
        XCTAssertNil(engine.evaluate("   "))
        XCTAssertNil(engine.evaluate("5"))
        XCTAssertNil(engine.evaluate("zzz"))
    }

    func test_routesForgivingAliases() {
        let engine = makeEngine()
        XCTAssertEqual(engine.evaluate("tdy")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(engine.evaluate("10 km to mi")?.insertionText, "6.214 mi")
        XCTAssertEqual(engine.evaluate("$100 to eur")?.insertionText, "€92.00")
        XCTAssertEqual(engine.evaluate("roll")?.insertionText, "1")
    }
}
