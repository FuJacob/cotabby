import Foundation

/// File overview:
/// Safe arithmetic for `/` macros: `+ - * / ^`, parentheses, unary sign, decimals, and a trailing
/// `%` meaning percent (value divided by 100). `x`, `X`, and `×` mean multiply; `÷` means divide.
///
/// We deliberately do NOT use `NSExpression`: it can evaluate function calls and key paths, which is
/// an injection risk for arbitrary user text. This hand-written recursive-descent parser only ever
/// produces a number, and is pure and deterministic.
///
/// The preview shows the worked form (`= 10`), but accepting inserts only the result, so `/5+5=`
/// becomes `10`. A bare number with no operator (`/5`) is intentionally not a result, so the macro
/// stays out of the way of ordinary typing.
struct ArithmeticEvaluator: MacroEvaluating {
    func evaluate(_ query: String) -> MacroResult? {
        // A trailing `=` is the user's "compute now" cue; strip it before parsing. Accepting replaces
        // the whole `/expr=` run with just the result (so `/5+5=` becomes `10`).
        let literal = query.hasSuffix("=") ? String(query.dropLast()) : query
        guard !literal.isEmpty else { return nil }

        let normalized = literal
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")

        var parser = Parser(normalized)
        guard let value = parser.parse(), parser.usedOperator, value.isFinite else { return nil }
        guard let resultText = Self.format(value) else { return nil }

        return MacroResult(previewText: "= \(resultText)", insertionText: resultText)
    }

    /// Formats a result: integers print without a decimal point; everything else prints with up to
    /// 10 significant digits and trailing zeros trimmed. Non-finite values return `nil`.
    static func format(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == value.rounded(), value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.10g", value)
    }

    /// Thrown by `Parser` at the first point the text stops being a well-formed expression. Nothing
    /// is recovered from a bad parse, so one case is enough.
    private nonisolated struct Malformed: Error {}

    /// Recursive-descent parser over the operator grammar. `usedOperator` gates "is this actually an
    /// expression" so a lone number or a unary-signed number is not treated as a macro.
    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private(set) var usedOperator = false

        init(_ string: String) {
            characters = Array(string.filter { !$0.isWhitespace })
        }

        /// The value of the whole text, or `nil` when it is malformed or has input left over.
        mutating func parse() -> Double? {
            guard let value = try? parseExpression(), index == characters.count else { return nil }
            return value
        }

        private mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while let op = peek(), op == "+" || op == "-" {
                advance()
                usedOperator = true
                let rhs = try parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parsePower()
            while let op = peek(), op == "*" || op == "/" {
                advance()
                usedOperator = true
                let rhs = try parsePower()
                if op == "/" {
                    guard rhs != 0 else { throw Malformed() }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func parsePower() throws -> Double {
            let base = try parseUnary()
            if peek() == "^" {
                advance()
                usedOperator = true
                let exponent = try parsePower()   // right associative
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parseUnary() throws -> Double {
            if peek() == "-" {
                advance()
                return try -parsePostfix()
            }
            if peek() == "+" {
                advance()
                return try parsePostfix()
            }
            return try parsePostfix()
        }

        private mutating func parsePostfix() throws -> Double {
            var value = try parsePrimary()
            while peek() == "%" {
                advance()
                usedOperator = true
                value /= 100
            }
            return value
        }

        private mutating func parsePrimary() throws -> Double {
            if peek() == "(" {
                advance()
                let value = try parseExpression()
                guard peek() == ")" else { throw Malformed() }
                advance()
                return value
            }
            return try parseNumber()
        }

        private mutating func parseNumber() throws -> Double {
            var digits = ""
            while let character = peek(), character.isNumber || character == "." {
                digits.append(character)
                advance()
            }
            guard let value = Double(digits) else { throw Malformed() }
            return value
        }

        private func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        private mutating func advance() {
            index += 1
        }
    }
}
