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

    /// Recursive-descent parser over the operator grammar. `usedOperator` gates "is this actually an
    /// expression" so a lone number or a unary-signed number is not treated as a macro.
    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private(set) var usedOperator = false
        private var valid = true

        init(_ string: String) {
            characters = Array(string.filter { !$0.isWhitespace })
        }

        mutating func parse() -> Double? {
            let value = parseExpression()
            guard valid, index == characters.count else { return nil }
            return value
        }

        private mutating func parseExpression() -> Double {
            var value = parseTerm()
            while let op = peek(), op == "+" || op == "-" {
                advance()
                usedOperator = true
                let rhs = parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double {
            var value = parsePower()
            while let op = peek(), op == "*" || op == "/" {
                advance()
                usedOperator = true
                let rhs = parsePower()
                if op == "/" {
                    if rhs == 0 {
                        valid = false
                        return 0
                    }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        private mutating func parsePower() -> Double {
            let base = parseUnary()
            if peek() == "^" {
                advance()
                usedOperator = true
                let exponent = parsePower()   // right associative
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parseUnary() -> Double {
            if peek() == "-" {
                advance()
                return -parsePostfix()
            }
            if peek() == "+" {
                advance()
                return parsePostfix()
            }
            return parsePostfix()
        }

        private mutating func parsePostfix() -> Double {
            var value = parsePrimary()
            while peek() == "%" {
                advance()
                usedOperator = true
                value /= 100
            }
            return value
        }

        private mutating func parsePrimary() -> Double {
            if peek() == "(" {
                advance()
                let value = parseExpression()
                if peek() == ")" {
                    advance()
                } else {
                    valid = false
                }
                return value
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double {
            var digits = ""
            while let character = peek(), character.isNumber || character == "." {
                digits.append(character)
                advance()
            }
            guard let value = Double(digits) else {
                valid = false
                return 0
            }
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
