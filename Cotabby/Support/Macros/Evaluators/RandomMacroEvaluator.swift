import Foundation

/// File overview:
/// Random and generator macros: `/random` (`/rand`, `/rnd`), `/random(n)`, `/random(a,b)`, `/dice`
/// (`/roll`, `/die`, and `/dN` dice notation like `/d20`), `/coin` (`/flip`), `/uuid` (`/guid`). The
/// RNG and UUID source are injected so tests are deterministic.
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
        case "uuid", "guid":
            return MacroResult(uuidSource())
        case "dice", "die", "roll":
            return MacroResult(String(randomSource(1...6)))
        case "coin", "flip", "coinflip", "coin-flip":
            return MacroResult(randomSource(0...1) == 0 ? "Heads" : "Tails")
        case "random", "rand", "rnd":
            return MacroResult(String(randomSource(0...100)))
        default:
            if let sides = Self.diceSides(lower) {
                return MacroResult(String(randomSource(1...sides)))
            }
            return parameterizedRandom(lower)
        }
    }

    /// `dN` dice notation: `/d20` rolls 1...20. Returns the side count, or nil when the token is not
    /// `d` followed by a positive integer (so `/d` and `/dollar` fall through to other families).
    private static func diceSides(_ lower: String) -> Int? {
        guard lower.hasPrefix("d"), lower.count > 1, let sides = Int(lower.dropFirst()), sides >= 1 else {
            return nil
        }
        return sides
    }

    /// Handles `random(n)` / `random(a,b)` (and the `rand(...)` / `rnd(...)` short forms) with integer
    /// arguments, normalizing reversed bounds.
    private func parameterizedRandom(_ lower: String) -> MacroResult? {
        let prefixes = ["random(", "rand(", "rnd("]
        guard prefixes.contains(where: { lower.hasPrefix($0) }),
              lower.hasSuffix(")"), let open = lower.firstIndex(of: "(") else {
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
