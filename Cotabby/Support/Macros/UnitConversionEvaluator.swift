import Foundation

/// File overview:
/// Physical-unit conversion macros, fully offline and native via Foundation `Measurement`:
/// `/10km->mi`, `/100f->c`, `/5ft->m`, `/2lb->kg`, `/3cup->ml`. The from and to tokens must
/// belong to the same quantity (length, mass, temperature, volume); a cross-quantity request
/// returns `nil` so currency can try the same `->` string next.
///
/// Tokens are resolved through an explicit table so ambiguous abbreviations are unsurprising:
/// `m` is meters, `min` is not a unit here, `c` is Celsius, `oz` is ounce-mass with `floz` for
/// fluid ounce. Output is locale formatted.
struct UnitConversionEvaluator: MacroEvaluating {
    private let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func evaluate(_ query: String) -> MacroResult? {
        guard let arrow = query.range(of: "->") else { return nil }
        let lhs = query[query.startIndex..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let toToken = query[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()

        let numberPart = lhs.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        let fromToken = lhs.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).lowercased()
        guard let value = Double(numberPart), !fromToken.isEmpty, !toToken.isEmpty,
              let from = Self.units[fromToken], let to = Self.units[toToken],
              let converted = Self.convert(value, from: from, to: to) else {
            return nil
        }

        let formatted = "\(Self.format(converted)) \(toToken)"
        return MacroResult(formatted)
    }

    private enum Quantity {
        case length(UnitLength)
        case mass(UnitMass)
        case temperature(UnitTemperature)
        case volume(UnitVolume)
    }

    private static func convert(_ value: Double, from: Quantity, to: Quantity) -> Double? {
        switch (from, to) {
        case let (.length(source), .length(target)):
            return Measurement(value: value, unit: source).converted(to: target).value
        case let (.mass(source), .mass(target)):
            return Measurement(value: value, unit: source).converted(to: target).value
        case let (.temperature(source), .temperature(target)):
            return Measurement(value: value, unit: source).converted(to: target).value
        case let (.volume(source), .volume(target)):
            return Measurement(value: value, unit: source).converted(to: target).value
        default:
            return nil   // cross-quantity: not a unit conversion
        }
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded(), value.magnitude < 1e12 {
            return String(Int64(value))
        }
        return String(format: "%.4g", value)
    }

    private static let units: [String: Quantity] = [
        // Length
        "mm": .length(.millimeters), "cm": .length(.centimeters), "m": .length(.meters),
        "km": .length(.kilometers), "in": .length(.inches), "ft": .length(.feet),
        "yd": .length(.yards), "mi": .length(.miles),
        // Mass
        "mg": .mass(.milligrams), "g": .mass(.grams), "kg": .mass(.kilograms),
        "oz": .mass(.ounces), "lb": .mass(.pounds), "lbs": .mass(.pounds), "st": .mass(.stones),
        // Temperature
        "c": .temperature(.celsius), "f": .temperature(.fahrenheit), "k": .temperature(.kelvin),
        // Volume
        "ml": .volume(.milliliters), "l": .volume(.liters), "cup": .volume(.cups),
        "cups": .volume(.cups), "tbsp": .volume(.tablespoons), "tsp": .volume(.teaspoons),
        "floz": .volume(.fluidOunces), "gal": .volume(.gallons), "pt": .volume(.pints),
        "qt": .volume(.quarts)
    ]
}
