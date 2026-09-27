import XCTest
@testable import Cotabby

/// Tests for the offline currency conversion macros and their bundled rate table.
///
/// Rates are units-per-USD, so every conversion crosses through USD. Formatting uses the target
/// currency's locale style (`en_US` here, so EUR renders `€92.00` and JPY renders without decimals).
/// Custom `CurrencyRateTable`s isolate the cross-rate math from the bundled, periodically refreshed
/// values.
final class CurrencyEvaluatorTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private lazy var sut = CurrencyEvaluator(locale: locale)

    // MARK: - Conversion math and formatting

    func test_sameCurrency_isIdentity() {
        XCTAssertEqual(sut.evaluate("100USD->USD")?.insertionText, "$100.00")
    }

    func test_crossRate_goesThroughUSD() {
        // 136 CAD / 1.36 (CAD per USD) = 100 USD.
        XCTAssertEqual(sut.evaluate("136CAD->USD")?.insertionText, "$100.00")
    }

    func test_targetCurrencyFormatting_followsTheTargetCode() {
        XCTAssertEqual(sut.evaluate("100USD->EUR")?.insertionText, "€92.00")
        XCTAssertEqual(sut.evaluate("100USD->GBP")?.insertionText, "£79.00")
        // JPY has no minor unit, so the formatter drops the decimals entirely.
        XCTAssertEqual(sut.evaluate("100USD->JPY")?.insertionText, "¥15,100")
    }

    func test_previewMatchesInsertion() {
        XCTAssertEqual(sut.evaluate("100USD->EUR"), MacroResult("€92.00"))
    }

    func test_injectedRateTable_drivesTheCrossRate() {
        let table = CurrencyRateTable(asOf: "test", ratesPerUSD: ["USD": 1, "EUR": 0.5, "GBP": 0.25])
        let custom = CurrencyEvaluator(locale: locale, table: table)
        XCTAssertEqual(custom.evaluate("10 usd to eur")?.insertionText, "€5.00")
        // EUR -> GBP never touches a direct pair: 10 EUR / 0.5 = 20 USD, * 0.25 = 5 GBP.
        XCTAssertEqual(custom.evaluate("10EUR->GBP")?.insertionText, "£5.00")
    }

    func test_codeMissingFromTable_returnsNil() {
        let table = CurrencyRateTable(asOf: "test", ratesPerUSD: ["USD": 1])
        XCTAssertNil(CurrencyEvaluator(locale: locale, table: table).evaluate("100USD->EUR"))
    }

    // MARK: - Token resolution

    func test_aliasesSymbolsAndCaseVariants_resolveToTheSameCode() {
        for query in ["100us->eur", "$100 to eur", "$ 100 to eur", "100 dollars to euros", "100usd->€", "100 USD to EUR"] {
            XCTAssertEqual(sut.evaluate(query)?.insertionText, "€92.00", query)
        }
    }

    func test_multiCharacterSymbol_resolvesAsTrailingToken() {
        // `c$` is a two-character alias, so it only resolves after the amount; the leading-symbol
        // path inspects a single character.
        XCTAssertEqual(sut.evaluate("136 c$ to usd")?.insertionText, "$100.00")
    }

    func test_ambiguousCurrencyWords_areDeliberatelyUnresolved() {
        // `kr` / `krona` are shared by several countries, so the macro refuses to guess.
        XCTAssertNil(sut.evaluate("100 kr to usd"))
        XCTAssertNil(sut.evaluate("100 krona to usd"))
    }

    func test_unknownOrMalformedCodes_returnNil() {
        XCTAssertNil(sut.evaluate("100XXX->USD"))
        XCTAssertNil(sut.evaluate("100USDX->EUR"))
        XCTAssertNil(sut.evaluate("USD->EUR"))
        XCTAssertNil(sut.evaluate("100USD EUR"))
    }

    // MARK: - Rate table

    func test_rateLookup_isCaseInsensitive() {
        XCTAssertEqual(CurrencyRateTable.bundled.rate(for: "usd"), 1.0)
        XCTAssertEqual(CurrencyRateTable.bundled.rate(for: "EUR"), CurrencyRateTable.bundled.rate(for: "eur"))
        XCTAssertNil(CurrencyRateTable.bundled.rate(for: "XXX"))
    }
}
