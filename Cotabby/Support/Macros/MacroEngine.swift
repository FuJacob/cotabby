import Foundation

/// File overview:
/// Aggregates the macro families and tries them in priority order, returning the first match. The
/// order matters only where families could both claim a string: dates and random are keyword based
/// and specific; unit and currency both key off `->` but each returns `nil` for the other's tokens;
/// arithmetic is the catch-all for operator expressions.
///
/// The clock and RNG are injected so the whole engine is deterministic under test.
struct MacroEngine {
    private let evaluators: [MacroEvaluating]

    init(evaluators: [MacroEvaluating]) {
        self.evaluators = evaluators
    }

    /// The production engine.
    static func standard(
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current,
        locale: Locale = .current,
        randomSource: @escaping (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
    ) -> MacroEngine {
        MacroEngine(evaluators: [
            DateMacroEvaluator(now: now, calendar: calendar, locale: locale),
            RandomMacroEvaluator(randomSource: randomSource),
            UnitConversionEvaluator(locale: locale),
            CurrencyEvaluator(locale: locale),
            ArithmeticEvaluator()
        ])
    }

    /// Returns the result for the typed `/query` (without the `/`), or `nil` when nothing matches.
    func evaluate(_ query: String) -> MacroResult? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for evaluator in evaluators {
            if let result = evaluator.evaluate(trimmed) {
                return result
            }
        }
        return nil
    }
}
