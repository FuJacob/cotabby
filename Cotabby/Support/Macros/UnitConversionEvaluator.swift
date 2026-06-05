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
        guard let (lhsRaw, rhsRaw) = ConversionSeparator.split(query) else { return nil }
        let lhs = lhsRaw.trimmingCharacters(in: .whitespaces)
        let toToken = rhsRaw.trimmingCharacters(in: .whitespaces).lowercased()

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
        "mm": .length(.millimeters), "millimeter": .length(.millimeters), "millimeters": .length(.millimeters),
        "millimetre": .length(.millimeters), "millimetres": .length(.millimeters),
        "cm": .length(.centimeters), "centimeter": .length(.centimeters), "centimeters": .length(.centimeters),
        "centimetre": .length(.centimeters), "centimetres": .length(.centimeters),
        "m": .length(.meters), "meter": .length(.meters), "meters": .length(.meters),
        "metre": .length(.meters), "metres": .length(.meters),
        "km": .length(.kilometers), "kilometer": .length(.kilometers), "kilometers": .length(.kilometers),
        "kilometre": .length(.kilometers), "kilometres": .length(.kilometers),
        "in": .length(.inches), "inch": .length(.inches), "inches": .length(.inches),
        "ft": .length(.feet), "foot": .length(.feet), "feet": .length(.feet),
        "yd": .length(.yards), "yard": .length(.yards), "yards": .length(.yards),
        "mi": .length(.miles), "mile": .length(.miles), "miles": .length(.miles),
        // Mass
        "mg": .mass(.milligrams), "milligram": .mass(.milligrams), "milligrams": .mass(.milligrams),
        "g": .mass(.grams), "gram": .mass(.grams), "grams": .mass(.grams),
        "kg": .mass(.kilograms), "kgs": .mass(.kilograms), "kilo": .mass(.kilograms), "kilos": .mass(.kilograms),
        "kilogram": .mass(.kilograms), "kilograms": .mass(.kilograms),
        "oz": .mass(.ounces), "ounce": .mass(.ounces), "ounces": .mass(.ounces),
        "lb": .mass(.pounds), "lbs": .mass(.pounds), "pound": .mass(.pounds), "pounds": .mass(.pounds),
        "st": .mass(.stones), "stone": .mass(.stones), "stones": .mass(.stones),
        // Temperature
        "c": .temperature(.celsius), "celsius": .temperature(.celsius), "centigrade": .temperature(.celsius),
        "f": .temperature(.fahrenheit), "fahrenheit": .temperature(.fahrenheit),
        "k": .temperature(.kelvin), "kelvin": .temperature(.kelvin),
        // Volume
        "ml": .volume(.milliliters), "milliliter": .volume(.milliliters), "milliliters": .volume(.milliliters),
        "millilitre": .volume(.milliliters), "millilitres": .volume(.milliliters),
        "l": .volume(.liters), "liter": .volume(.liters), "liters": .volume(.liters),
        "litre": .volume(.liters), "litres": .volume(.liters),
        "cup": .volume(.cups), "cups": .volume(.cups),
        "tbsp": .volume(.tablespoons), "tablespoon": .volume(.tablespoons), "tablespoons": .volume(.tablespoons),
        "tsp": .volume(.teaspoons), "teaspoon": .volume(.teaspoons), "teaspoons": .volume(.teaspoons),
        "floz": .volume(.fluidOunces),
        "gal": .volume(.gallons), "gallon": .volume(.gallons), "gallons": .volume(.gallons),
        "pt": .volume(.pints), "pint": .volume(.pints), "pints": .volume(.pints),
        "qt": .volume(.quarts), "quart": .volume(.quarts), "quarts": .volume(.quarts)
    ]
}
