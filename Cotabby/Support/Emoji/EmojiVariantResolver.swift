import Foundation

/// File overview:
/// Pure rules that turn raw matcher results into the variant-aware rows the picker shows: prefer the
/// configured gender variant (collapsing neutral/man/woman siblings of the same concept), then
/// compose the configured skin tone onto emoji that support it. When a non-default skin tone exists,
/// the default glyph remains available as the next row so users can still choose the unmodified
/// variant. Dependency-free so it is trivially unit testable; the bundled catalog carries no
/// skin-tone/gender metadata, so the policy lives here.
enum EmojiVariantResolver {
    /// Applies gender preference first (so skin tone composes onto the chosen variant), then skin tone.
    static func resolve(_ matches: [EmojiMatch], preferences: EmojiVariantPreferences) -> [EmojiMatch] {
        let genderResolved = applyGender(matches, gender: preferences.gender)
        return applySkinTone(genderResolved, skinTone: preferences.skinTone)
    }

    // MARK: - Gender

    /// Collapses neutral/man/woman variants of one concept (e.g. `firefighter` / `man_firefighter` /
    /// `woman_firefighter`) down to the preferred gender, falling back to neutral then to whatever is
    /// present. Concepts that appear with a single variant are not a gendered family and pass through.
    private static func applyGender(_ matches: [EmojiMatch], gender: EmojiGender) -> [EmojiMatch] {
        var orderedConcepts: [String] = []
        var variantsByConcept: [String: [EmojiGender: EmojiMatch]] = [:]

        for match in matches {
            let (variantGender, concept) = genderVariant(of: match)
            if variantsByConcept[concept] == nil {
                orderedConcepts.append(concept)
                variantsByConcept[concept] = [:]
            }
            // Keep the first (highest-ranked) match seen for each gender of a concept.
            if variantsByConcept[concept]?[variantGender] == nil {
                variantsByConcept[concept]?[variantGender] = match
            }
        }

        return orderedConcepts.compactMap { concept in
            guard let variants = variantsByConcept[concept] else { return nil }
            if variants.count == 1 { return variants.values.first }
            return variants[gender] ?? variants[.neutral] ?? variants.values.first
        }
    }

    /// Classifies a match's gender and base concept from its primary alias, using the dataset's
    /// `man_` / `woman_` prefix convention (`man_firefighter` -> (.male, "firefighter")).
    private static func genderVariant(of match: EmojiMatch) -> (EmojiGender, String) {
        let alias = match.entry.aliases.first ?? match.entry.name
        if let concept = alias.removingPrefix("man_") { return (.male, concept) }
        if let concept = alias.removingPrefix("woman_") { return (.female, concept) }
        return (.neutral, alias)
    }

    // MARK: - Skin tone

    private static func applySkinTone(
        _ matches: [EmojiMatch],
        skinTone: EmojiSkinTone
    ) -> [EmojiMatch] {
        guard let modifier = skinTone.modifier else { return matches }   // neutral: nothing to apply

        return matches.flatMap { match -> [EmojiMatch] in
            guard let toned = tonedGlyph(match.glyph, modifier: modifier) else {
                return [match]   // emoji does not support skin tone
            }
            let tonedMatch = EmojiMatch(entry: match.entry, displayGlyph: toned)
            return [tonedMatch, match]
        }
    }

    /// Inserts the Fitzpatrick `modifier` after the leading scalar when that scalar is a modifier
    /// base. Handles single-codepoint emoji (👋 -> 👋🏽) and ZWJ sequences whose first scalar is a
    /// person (🧑‍🚒 -> 🧑🏽‍🚒). Returns `nil` when the emoji does not support skin tone or already
    /// carries a modifier.
    static func tonedGlyph(_ glyph: String, modifier: String) -> String? {
        var scalars = Array(glyph.unicodeScalars)
        guard let first = scalars.first, isModifierBase(first) else { return nil }
        if scalars.count > 1, (0x1F3FB...0x1F3FF).contains(scalars[1].value) { return nil }
        guard let modifierScalar = modifier.unicodeScalars.first else { return nil }
        scalars.insert(modifierScalar, at: 1)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Unicode `Emoji_Modifier_Base` set: the emoji that accept a skin-tone modifier. Embedded because
    /// the bundled catalog has no skin-tone metadata. Matching this exact set avoids composing a
    /// modifier onto an emoji that does not support one (which renders as a broken glyph pair); an
    /// emoji missing from the set simply shows untoned, which is the safe degradation.
    static func isModifierBase(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x261D, 0x26F9, 0x270A...0x270D, 0x1F385,
             0x1F3C2...0x1F3C4, 0x1F3C7, 0x1F3CA...0x1F3CC,
             0x1F442...0x1F443, 0x1F446...0x1F450, 0x1F466...0x1F478, 0x1F47C,
             0x1F481...0x1F483, 0x1F485...0x1F487, 0x1F48F, 0x1F491, 0x1F4AA,
             0x1F574...0x1F575, 0x1F57A, 0x1F590, 0x1F595...0x1F596,
             0x1F645...0x1F647, 0x1F64B...0x1F64F, 0x1F6A3, 0x1F6B4...0x1F6B6,
             0x1F6C0, 0x1F6CC, 0x1F90C, 0x1F90F, 0x1F918...0x1F91F, 0x1F926,
             0x1F930...0x1F939, 0x1F93C...0x1F93E, 0x1F977, 0x1F9B5...0x1F9B6,
             0x1F9B8...0x1F9B9, 0x1F9BB, 0x1F9CD...0x1F9CF, 0x1F9D1...0x1F9DD,
             0x1FAC3...0x1FAC5, 0x1FAF0...0x1FAF8:
            return true
        default:
            return false
        }
    }
}

private extension String {
    /// Returns the remainder after `prefix`, or `nil` when the string does not start with it.
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
