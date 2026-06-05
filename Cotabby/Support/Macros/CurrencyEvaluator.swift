import Foundation

/// File overview:
/// Currency conversion macros: `/123.45CAD->USD`. Rates come from a bundled, offline, approximate
/// table (Section: never touches the network), and the result is formatted with the target
/// currency's locale-aware style via `NumberFormatter` (so JPY shows no decimals, USD shows two).
struct CurrencyEvaluator: MacroEvaluating {
    private let locale: Locale
    private let table: CurrencyRateTable

    init(locale: Locale = .current, table: CurrencyRateTable = .bundled) {
        self.locale = locale
        self.table = table
    }

    func evaluate(_ query: String) -> MacroResult? {
        guard let arrow = query.range(of: "->") else { return nil }
        let lhs = query[query.startIndex..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let toCode = query[arrow.upperBound...].trimmingCharacters(in: .whitespaces).uppercased()

        let numberPart = lhs.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        let fromCode = lhs.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).uppercased()
        guard let amount = Double(numberPart),
              fromCode.count == 3, toCode.count == 3,
              let fromRate = table.rate(for: fromCode),
              let toRate = table.rate(for: toCode) else {
            return nil
        }

        // Rates are units-per-USD, so cross through USD: amount / fromRate gives USD, then * toRate.
        let converted = (amount / fromRate) * toRate
        let formatted = formatCurrency(converted, code: toCode)
        return MacroResult(formatted)
    }

    private func formatCurrency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }
}

/// Bundled, offline, approximate exchange rates. Values are units of the currency per one US dollar.
/// Approximate by design and refreshed when the app is updated; this never reaches the network, in
/// keeping with Cotabby's on-device posture.
struct CurrencyRateTable {
    /// Human-readable "rates as of" marker, surfaced in settings/help so users know they are dated.
    let asOf: String
    private let ratesPerUSD: [String: Double]

    init(asOf: String, ratesPerUSD: [String: Double]) {
        self.asOf = asOf
        self.ratesPerUSD = ratesPerUSD
    }

    func rate(for code: String) -> Double? {
        ratesPerUSD[code.uppercased()]
    }

    static let bundled = CurrencyRateTable(
        asOf: "2026-06",
        ratesPerUSD: [
            "USD": 1.0, "EUR": 0.92, "GBP": 0.79, "JPY": 151.0, "CAD": 1.36, "AUD": 1.51,
            "CHF": 0.90, "CNY": 7.24, "INR": 83.4, "MXN": 17.1, "BRL": 5.05, "ZAR": 18.6,
            "KRW": 1360.0, "SGD": 1.35, "HKD": 7.82, "NZD": 1.63, "SEK": 10.5, "NOK": 10.7,
            "DKK": 6.87, "PLN": 3.95, "TRY": 32.1, "RUB": 90.0, "AED": 3.67, "SAR": 3.75,
            "THB": 36.5, "IDR": 15800.0, "MYR": 4.70, "PHP": 56.5, "CZK": 23.2, "HUF": 360.0,
            "ILS": 3.70, "TWD": 32.3
        ]
    )
}
