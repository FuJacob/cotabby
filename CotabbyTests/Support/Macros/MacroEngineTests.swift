import XCTest
@testable import Cotabby

/// Tests for the engine that routes a `/query` to the first matching macro family, plus the shared
/// conversion-separator parser the unit and currency families both depend on. Per-family behavior
/// lives in the `Evaluators/` suites; these tests pin routing order and query normalization only.
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

    /// Records every query it sees and answers with a fixed result (or nil), so routing order and
    /// the exact string forwarded to each family are observable.
    private final class StubEvaluator: MacroEvaluating {
        let result: MacroResult?
        private(set) var receivedQueries: [String] = []

        init(result: MacroResult?) {
            self.result = result
        }

        func evaluate(_ query: String) -> MacroResult? {
            receivedQueries.append(query)
            return result
        }
    }

    // MARK: - Standard engine

    func test_routesToEachFamily() {
        let engine = makeEngine()
        XCTAssertEqual(engine.evaluate("today")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(engine.evaluate("5+5")?.previewText, "= 10")
        XCTAssertEqual(engine.evaluate("10km->mi")?.insertionText, "6.214 mi")
        XCTAssertEqual(engine.evaluate("136CAD->USD")?.insertionText, "$100.00")
        XCTAssertEqual(engine.evaluate("random(7,7)")?.insertionText, "7")
    }

    func test_routesForgivingAliases() {
        let engine = makeEngine()
        XCTAssertEqual(engine.evaluate("tdy")?.insertionText, "Jun 4, 2026")
        XCTAssertEqual(engine.evaluate("10 km to mi")?.insertionText, "6.214 mi")
        XCTAssertEqual(engine.evaluate("$100 to eur")?.insertionText, "€92.00")
        XCTAssertEqual(engine.evaluate("roll")?.insertionText, "1")
    }

    func test_sharedWordRoutesByTarget_unitBeforeCurrency() {
        // "pound" is both a mass unit and a currency alias. The unit family runs first and claims it
        // only when the target is also a mass; otherwise it returns nil and currency takes over.
        let engine = makeEngine()
        XCTAssertEqual(engine.evaluate("1 pound to kg")?.insertionText, "0.4536 kg")
        XCTAssertEqual(engine.evaluate("1 pound to usd")?.insertionText, "$1.27")
    }

    func test_surroundingSpacesAreTrimmedBeforeRouting() {
        XCTAssertEqual(makeEngine().evaluate("  5+5  ")?.insertionText, "10")
    }

    func test_emptyAndUnknownReturnNil() {
        let engine = makeEngine()
        XCTAssertNil(engine.evaluate(""))
        XCTAssertNil(engine.evaluate("   "))
        XCTAssertNil(engine.evaluate("5"))
        XCTAssertNil(engine.evaluate("zzz"))
    }

    // MARK: - Routing mechanics

    func test_firstMatchingEvaluatorWins_andLaterOnesAreNotConsulted() {
        let declining = StubEvaluator(result: nil)
        let first = StubEvaluator(result: MacroResult("first"))
        let second = StubEvaluator(result: MacroResult("second"))
        let engine = MacroEngine(evaluators: [declining, first, second])

        XCTAssertEqual(engine.evaluate("q")?.insertionText, "first")
        XCTAssertEqual(declining.receivedQueries, ["q"])
        XCTAssertEqual(first.receivedQueries, ["q"])
        XCTAssertTrue(second.receivedQueries.isEmpty)
    }

    func test_evaluatorsReceiveTheTrimmedQuery_andBlankQueriesNeverReachThem() {
        let stub = StubEvaluator(result: nil)
        let engine = MacroEngine(evaluators: [stub])

        XCTAssertNil(engine.evaluate(" \t "))
        XCTAssertTrue(stub.receivedQueries.isEmpty)

        _ = engine.evaluate("  a b  ")
        XCTAssertEqual(stub.receivedQueries, ["a b"])
    }
}

/// Tests for the separator parser shared by the unit and currency families.
final class ConversionSeparatorTests: XCTestCase {
    func test_splitsOnEachSupportedSeparator() {
        let cases: [(query: String, left: String, right: String)] = [
            ("10km->mi", "10km", "mi"),
            ("10km→mi", "10km", "mi"),
            ("10 km to mi", "10 km", "mi"),
            ("10 km TO mi", "10 km", "mi")
        ]
        for (query, left, right) in cases {
            let split = ConversionSeparator.split(query)
            XCTAssertEqual(split?.left, left, query)
            XCTAssertEqual(split?.right, right, query)
        }
    }

    func test_sidesAreReturnedUntrimmed() {
        // Callers own trimming; the parser only cuts at the separator.
        let split = ConversionSeparator.split("10 km -> mi")
        XCTAssertEqual(split?.left, "10 km ")
        XCTAssertEqual(split?.right, " mi")
    }

    func test_arrowTakesPrecedenceOverSpacedTo() {
        let split = ConversionSeparator.split("a to b->c")
        XCTAssertEqual(split?.left, "a to b")
        XCTAssertEqual(split?.right, "c")
    }

    func test_toMustBeSpaceDelimited() {
        // "to" inside a word (or without surrounding spaces) is not a separator.
        XCTAssertNil(ConversionSeparator.split("tomato"))
        XCTAssertNil(ConversionSeparator.split("10kmtomi"))
        XCTAssertNil(ConversionSeparator.split("10km mi"))
    }
}
