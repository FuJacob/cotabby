import Foundation

/// File overview:
/// Random and generator macros: `/random`, `/random(n)`, `/random(a,b)`, `/dice`, `/coin`,
/// `/uuid`. The RNG and UUID source are injected so tests are deterministic.
struct RandomMacroEvaluator: MacroEvaluating {
    private let randomSource: (ClosedRange<Int>) -> Int
    private let uuidSource: () -> String

    init(
        randomSource: @escaping (ClosedRange<Int>) -> Int = { Int.random(in: $0) },
        uuidSource: @escaping () -> String = { UUID().uuidString }
    ) {
        self.randomSource = randomSource
        self.uuidSource = uuidSource
    }

    func evaluate(_ query: String) -> MacroResult? {
        let lower = query.lowercased()
        switch lower {
        case "uuid":
            return MacroResult(uuidSource())
        case "dice":
            return MacroResult(String(randomSource(1...6)))
        case "coin":
            return MacroResult(randomSource(0...1) == 0 ? "Heads" : "Tails")
        case "random":
            return MacroResult(String(randomSource(0...100)))
        default:
            return parameterizedRandom(lower)
        }
    }

    /// Handles `random(n)` and `random(a,b)` with integer arguments, normalizing reversed bounds.
    private func parameterizedRandom(_ lower: String) -> MacroResult? {
        guard lower.hasPrefix("random("), lower.hasSuffix(")"), let open = lower.firstIndex(of: "(") else {
            return nil
        }
        let inner = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, !values.isEmpty else { return nil }

        switch values.count {
        case 1:
            guard values[0] >= 1 else { return nil }
            return MacroResult(String(randomSource(1...values[0])))
        case 2:
            let low = min(values[0], values[1])
            let high = max(values[0], values[1])
            return MacroResult(String(randomSource(low...high)))
        default:
            return nil
        }
    }
}
