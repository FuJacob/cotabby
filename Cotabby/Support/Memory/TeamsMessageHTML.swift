import Foundation

/// File overview:
/// Turns the HTML of a Teams message into the plain text conversation memory stores.
///
/// Why its own file: Teams writes most messages as HTML (`RichText/Html`): paragraphs and `<div>`s
/// for lines, `<span itemtype=".../Mention">` around names, and quoted replies as
/// `<blockquote itemtype=".../Reply">`. The rules follow CPython's `html.parser` and
/// `html.unescape`, which the first prototype used (see `TeamsMessageMapper`):
/// - block elements (`p`, `div`, `br`, `li`, `tr`, `h1`...`h6`) become line breaks;
/// - `blockquote`, `script` and `style` are dropped with everything inside them (a quoted reply
///   is the other message, already remembered on its own);
/// - everything else keeps its text, so a mention keeps the person's name;
/// - character references are decoded, non-breaking spaces become spaces, runs of spaces and of
///   line breaks collapse, and the result is trimmed.
///
/// Pure and deterministic; used by `TeamsMessageMapper` and pinned by `TeamsMessageMapperTests`.
/// The tokenizer follows CPython 3.14's `HTMLParser` (tag, comment, declaration and raw-text
/// rules) on Unicode scalars, the unit Python strings index by.
nonisolated enum TeamsMessageHTML {
    static func text(_ content: String) -> String {
        guard !content.isEmpty else { return "" }
        guard content.contains("<") else {
            return PythonText.strip(HTMLCharacterReferences.decode(content))
        }
        var extractor = Extractor()
        var tokenizer = Tokenizer(Array(content.unicodeScalars))
        tokenizer.run(into: &extractor)

        var scalars: [Unicode.Scalar] = []
        for part in extractor.parts {
            for scalar in part.unicodeScalars where scalar != "\r" {
                scalars.append(scalar == "\u{A0}" ? " " : scalar)
            }
        }
        return PythonText.strip(String(String.UnicodeScalarView(collapseWhitespace(scalars))))
    }

    /// `[ \t]+` -> " ", then ` *\n *` -> "\n", then `\n{2,}` -> "\n", in one pass: a space run is
    /// kept only when no line break touches it, and line break runs become one.
    static func collapseWhitespace(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" {
                var sawBreak = false
                while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" || scalars[index] == "\n" {
                    if scalars[index] == "\n" { sawBreak = true }
                    index += 1
                }
                output.append(sawBreak ? "\n" : " ")
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return output
    }

    // MARK: - Handler

    /// The Python `_TextExtractor`: what each tag and text run contributes.
    struct Extractor {
        static let blocks: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"]
        static let skipped: Set<String> = ["blockquote", "script", "style"]

        private(set) var parts: [String] = []
        private var skipping = 0

        mutating func startTag(_ tag: String) {
            if Self.skipped.contains(tag) {
                skipping += 1
            } else if Self.blocks.contains(tag), skipping == 0 {
                parts.append("\n")
            }
        }

        mutating func endTag(_ tag: String) {
            if Self.skipped.contains(tag) {
                skipping = max(0, skipping - 1)
            } else if Self.blocks.contains(tag), skipping == 0 {
                parts.append("\n")
            }
        }

        mutating func data(_ text: String) {
            if skipping == 0 { parts.append(text) }
        }
    }

    // MARK: - Tokenizer

    /// CPython's `HTMLParser.goahead` with `convert_charrefs=True`, fed the whole message at once
    /// and closed: text runs between tags are decoded and reported, tags reported by lowercased
    /// name, comments, declarations and processing instructions dropped, and the content of
    /// raw-text elements (`script`, `style`...) reported undecoded up to their end tag. A construct
    /// left open at the end of the message is dropped, as Python does.
    struct Tokenizer {
        private let scalars: [Unicode.Scalar]
        private var rawTextElement: String?
        private var rawTextDecodes = false

        static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "plaintext"]
        static let escapableRawText: Set<String> = ["textarea", "title"]

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        private var length: Int { scalars.count }

        private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "a"..."z", "A"..."Z": return true
            default: return false
            }
        }

        /// `[\t\n\r\f ]`
        private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" || scalar == " "
        }

        private func starts(with prefix: String, at index: Int) -> Bool {
            let prefixScalars = Array(prefix.unicodeScalars)
            guard index + prefixScalars.count <= length else { return false }
            for (offset, scalar) in prefixScalars.enumerated() where scalars[index + offset] != scalar { return false }
            return true
        }

        private func find(_ scalar: Unicode.Scalar, from index: Int) -> Int? {
            var position = index
            while position < length {
                if scalars[position] == scalar { return position }
                position += 1
            }
            return nil
        }

        private func string(_ start: Int, _ end: Int) -> String {
            String(String.UnicodeScalarView(scalars[start..<end]))
        }

        mutating func run(into handler: inout Extractor) {
            var index = 0
            while index < length {
                let textEnd: Int
                if let element = rawTextElement {
                    guard let end = rawTextEnd(element, from: index) else { break }
                    textEnd = end
                } else {
                    textEnd = find("<", from: index) ?? length
                }
                if index < textEnd {
                    let text = string(index, textEnd)
                    handler.data(rawTextElement == nil || rawTextDecodes ? HTMLCharacterReferences.decode(text) : text)
                }
                index = textEnd
                if index == length { break }

                var next = parseMarkup(at: index, into: &handler)
                if next < 0 {
                    // Unterminated at the end of the message: Python reports a lone "</" as text
                    // and drops everything else that is left.
                    if starts(with: "</", at: index), index + 2 == length { handler.data("</") }
                    next = length
                }
                index = next
            }
            if index < length {
                let text = string(index, length)
                handler.data(rawTextElement == nil || rawTextDecodes ? HTMLCharacterReferences.decode(text) : text)
            }
        }

        /// The construct starting with the `<` at `index`: a start or end tag, a comment, a processing
        /// instruction or a declaration, or a lone `<` reported as text. Returns where it ends, or -1
        /// when it is unterminated.
        private mutating func parseMarkup(at index: Int, into handler: inout Extractor) -> Int {
            if index + 1 < length, Self.isLetter(scalars[index + 1]) { return parseStartTag(index, into: &handler) }
            if starts(with: "</", at: index) { return parseEndTag(index, into: &handler) }
            if starts(with: "<!--", at: index) { return parseComment(index) }
            if starts(with: "<?", at: index) { return find(">", from: index + 2).map { $0 + 1 } ?? -1 }
            if starts(with: "<!", at: index) { return parseDeclaration(index) }
            handler.data("<")
            return index + 1
        }

        /// Whether the scalar at `position` can continue a tag name (`[^\t\n\r\f />]`).
        private func continuesTagName(_ position: Int) -> Bool {
            !Self.isSpace(scalars[position]) && scalars[position] != "/" && scalars[position] != ">"
        }

        /// Where `</element` followed by a space, `/` or `>` starts, case-insensitively.
        private func rawTextEnd(_ element: String, from index: Int) -> Int? {
            guard element != "plaintext" else { return nil }
            let name = Array(element.unicodeScalars)
            var position = index
            while position + 2 + name.count < length {
                if scalars[position] == "<", scalars[position + 1] == "/" {
                    var matches = true
                    for (offset, scalar) in name.enumerated() {
                        let candidate = scalars[position + 2 + offset]
                        let lowered = ("A"..."Z").contains(candidate) ? Unicode.Scalar(candidate.value + 32)! : candidate
                        if lowered != scalar { matches = false; break }
                    }
                    let next = scalars[position + 2 + name.count]
                    if matches, Self.isSpace(next) || next == "/" || next == ">" { return position }
                }
                position += 1
            }
            return nil
        }

        /// The end of a tag starting at `start` (its name's first letter), following Python's
        /// `locatetagend`: name, then attributes (a name, optionally `=` and a quoted or bare value),
        /// separated by spaces and slashes, then an optional `>`.
        private func locateTagEnd(_ start: Int) -> Int {
            var position = start + 1
            while position < length, continuesTagName(position) { position += 1 }
            while position < length, Self.isSpace(scalars[position]) || scalars[position] == "/" { position += 1 }
            while let end = attributeEnd(position) {
                position = end
                while position < length, Self.isSpace(scalars[position]) || scalars[position] == "/" { position += 1 }
            }
            if position < length, scalars[position] == ">" { position += 1 }
            return position
        }

        /// One attribute (name and optional value) starting at `position`, or nil when none can
        /// start there (`(?<=['"\t\n\r\f /])[^\t\n\r\f />][^\t\n\r\f /=>]*` and the value group).
        private func attributeEnd(_ position: Int) -> Int? {
            guard position < length, position > 0 else { return nil }
            let before = scalars[position - 1]
            guard before == "'" || before == "\"" || before == "/" || Self.isSpace(before) else { return nil }
            guard !Self.isSpace(scalars[position]), scalars[position] != "/", scalars[position] != ">" else { return nil }
            var end = position + 1
            while end < length, continuesTagName(end), scalars[end] != "=" { end += 1 }
            // Optional `[\t\n\r\f ]*=[\t\n\r\f ]*value`.
            var value = end
            while value < length, Self.isSpace(scalars[value]) { value += 1 }
            guard value < length, scalars[value] == "=" else { return end }
            value += 1
            while value < length, Self.isSpace(scalars[value]) { value += 1 }
            if value < length, scalars[value] == "'" || scalars[value] == "\"" {
                guard let close = find(scalars[value], from: value + 1) else { return end }
                return close + 1
            }
            while value < length, scalars[value] != ">", !Self.isSpace(scalars[value]) { value += 1 }
            return value
        }

        private mutating func parseStartTag(_ start: Int, into handler: inout Extractor) -> Int {
            let endpos = locateTagEnd(start + 1)
            guard endpos > 0, scalars[endpos - 1] == ">" else { return -1 }
            // Name: `[a-zA-Z][^\t\n\r\f />]*`, then `(?:[\t\n\r\f ]|/(?!>))*`.
            var cursor = start + 2
            while cursor < length, continuesTagName(cursor) { cursor += 1 }
            let tag = string(start + 1, cursor).lowercased()
            cursor = skipSpacesAndLoneSlashes(cursor)
            while cursor < endpos, let end = attributeEnd(cursor) {
                cursor = skipSpacesAndLoneSlashes(end)
            }
            let rest = PythonText.strip(string(cursor, endpos))
            guard rest == ">" || rest == "/>" else {
                handler.data(string(start, endpos))
                return endpos
            }
            if rest == "/>" {
                handler.startTag(tag)
                handler.endTag(tag)
            } else {
                handler.startTag(tag)
                if Self.rawText.contains(tag) {
                    rawTextElement = tag
                    rawTextDecodes = false
                } else if Self.escapableRawText.contains(tag) {
                    rawTextElement = tag
                    rawTextDecodes = true
                }
            }
            return endpos
        }

        private func skipSpacesAndLoneSlashes(_ index: Int) -> Int {
            var cursor = index
            while cursor < length,
                  Self.isSpace(scalars[cursor]) || (scalars[cursor] == "/" && !(cursor + 1 < length && scalars[cursor + 1] == ">")) {
                cursor += 1
            }
            return cursor
        }

        private mutating func parseEndTag(_ start: Int, into handler: inout Extractor) -> Int {
            guard find(">", from: start + 2) != nil else { return -1 }
            guard start + 2 < length, Self.isLetter(scalars[start + 2]) else {
                if start + 2 < length, scalars[start + 2] == ">" { return start + 3 } // `</>` is ignored
                return parseBogusComment(start)
            }
            let endpos = locateTagEnd(start + 2)
            guard scalars[endpos - 1] == ">" else { return -1 }
            var cursor = start + 3
            while cursor < length, continuesTagName(cursor) { cursor += 1 }
            handler.endTag(string(start + 2, cursor).lowercased())
            rawTextElement = nil
            rawTextDecodes = false
            return endpos
        }

        /// `<!--` up to `-->` or `--!>`; `<!-->` and `<!--->` close at once.
        private func parseComment(_ start: Int) -> Int {
            var position = start + 4
            while position < length {
                if starts(with: "-->", at: position) { return position + 3 }
                if starts(with: "--!>", at: position) { return position + 4 }
                position += 1
            }
            if starts(with: ">", at: start + 4) { return start + 5 }
            if starts(with: "->", at: start + 4) { return start + 6 }
            return -1
        }

        private func parseDeclaration(_ start: Int) -> Int {
            if starts(with: "<![CDATA[", at: start) {
                var position = start + 9
                while position < length {
                    if starts(with: "]]>", at: position) { return position + 3 }
                    position += 1
                }
                return -1
            }
            if string(start, min(start + 9, length)).lowercased() == "<!doctype" {
                return find(">", from: start + 9).map { $0 + 1 } ?? -1
            }
            return parseBogusComment(start)
        }

        private func parseBogusComment(_ start: Int) -> Int {
            find(">", from: start + 2).map { $0 + 1 } ?? -1
        }
    }
}

/// Python's `html.unescape`: numeric references (`&#246;`, `&#xF6;`, with the HTML5 fix-ups for
/// invalid code points) and named references, including the legacy names that need no `;`
/// (`&amp`, `&nbsp`) and the longest-prefix rule (`&ampfoo` -> `&foo`).
///
/// The named table is the HTML 4 set and every legacy name, generated from Python's
/// `html.entities.html5`; HTML5-only names (`&ZeroWidthSpace;` and similar) are left as written,
/// which Teams messages are not expected to use.
nonisolated enum HTMLCharacterReferences {
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let input = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < input.count {
            guard input[index] == "&", let (replacement, end) = reference(in: input, at: index) else {
                output.append(input[index])
                index += 1
                continue
            }
            output.append(contentsOf: replacement.unicodeScalars)
            index = end
        }
        return String(output)
    }

    /// The replacement for the reference starting at `start` (an `&`) and where it ends, following
    /// `&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)`; nil when nothing matches.
    private static func reference(in input: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        guard start + 1 < input.count else { return nil }
        if input[start + 1] == "#" { return numericReference(in: input, at: start + 2) }
        return namedReference(in: input, at: start)
    }

    /// `[xX]?digits;?` after `&#`. `&#` without digits is nil: the named form cannot start with `#`.
    private static func numericReference(in input: [Unicode.Scalar], at digitsOrX: Int) -> (String, Int)? {
        var position = digitsOrX
        var radix = 10
        if position < input.count, input[position] == "x" || input[position] == "X" {
            radix = 16
            position += 1
        }
        let digitsStart = position
        while position < input.count, isDigit(input[position], radix: radix) { position += 1 }
        guard position > digitsStart else { return nil }
        let digits = String(String.UnicodeScalarView(input[digitsStart..<position]))
        if position < input.count, input[position] == ";" { position += 1 }
        return (numeric(UInt32(digits, radix: radix)), position)
    }

    /// A named reference: the longest known name, which may be a prefix of what follows the `&`
    /// (`&ampfoo` -> `&foo`); unknown names are left as written.
    private static func namedReference(in input: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        var position = start + 1
        while position < input.count, position - start - 1 < 32, !isNameTerminator(input[position]) { position += 1 }
        guard position > start + 1 else { return nil }
        if position < input.count, input[position] == ";" { position += 1 }
        let name = String(String.UnicodeScalarView(input[(start + 1)..<position]))
        if let value = named[name] { return (value, position) }
        let scalars = Array(name.unicodeScalars)
        var length = scalars.count - 1
        while length > 1 {
            let prefix = String(String.UnicodeScalarView(scalars[0..<length]))
            if let value = named[prefix] {
                return (value + String(String.UnicodeScalarView(scalars[length...])), position)
            }
            length -= 1
        }
        return ("&" + name, position)
    }

    private static func isDigit(_ scalar: Unicode.Scalar, radix: Int) -> Bool {
        switch scalar {
        case "0"..."9": return true
        case "a"..."f", "A"..."F": return radix == 16
        default: return false
        }
    }

    private static func isNameTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == " " || scalar == "<"
            || scalar == "&" || scalar == "#" || scalar == ";"
    }

    /// A numeric reference's text; `nil` (overflow) is beyond Unicode.
    private static func numeric(_ value: UInt32?) -> String {
        guard let value else { return "\u{FFFD}" }
        if let replacement = invalidCharacterReferences[value] { return replacement }
        if (0xD800...0xDFFF).contains(value) || value > 0x10FFFF { return "\u{FFFD}" }
        if isInvalidCodePoint(value) { return "" }
        return Unicode.Scalar(value).map { String($0) } ?? "\u{FFFD}"
    }

    private static func isInvalidCodePoint(_ value: UInt32) -> Bool {
        switch value {
        case 0x1...0x8, 0xB, 0xE...0x1F, 0x7F...0x9F, 0xFDD0...0xFDEF: return true
        default: return value & 0xFFFE == 0xFFFE
        }
    }

    /// Code points HTML5 maps to something else (mostly Windows-1252 in the C1 range).
    private static let invalidCharacterReferences: [UInt32: String] = [
        0x00: "\u{FFFD}", 0x0D: "\r", 0x80: "\u{20AC}", 0x81: "\u{81}", 0x82: "\u{201A}", 0x83: "\u{192}",
        0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}", 0x87: "\u{2021}", 0x88: "\u{2C6}", 0x89: "\u{2030}",
        0x8A: "\u{160}", 0x8B: "\u{2039}", 0x8C: "\u{152}", 0x8D: "\u{8D}", 0x8E: "\u{17D}", 0x8F: "\u{8F}",
        0x90: "\u{90}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
        0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{2DC}", 0x99: "\u{2122}", 0x9A: "\u{161}", 0x9B: "\u{203A}",
        0x9C: "\u{153}", 0x9D: "\u{9D}", 0x9E: "\u{17E}", 0x9F: "\u{178}"
    ]

    static let named: [String: String] = [
        "AElig": "\u{C6}", "AElig;": "\u{C6}", "AMP": "&", "Aacute": "\u{C1}", "Aacute;": "\u{C1}",
        "Acirc": "\u{C2}", "Acirc;": "\u{C2}", "Agrave": "\u{C0}", "Agrave;": "\u{C0}", "Alpha;": "\u{391}",
        "Aring": "\u{C5}", "Aring;": "\u{C5}", "Atilde": "\u{C3}", "Atilde;": "\u{C3}", "Auml": "\u{C4}",
        "Auml;": "\u{C4}", "Beta;": "\u{392}", "COPY": "\u{A9}", "Ccedil": "\u{C7}", "Ccedil;": "\u{C7}",
        "Chi;": "\u{3A7}", "Dagger;": "\u{2021}", "Delta;": "\u{394}", "ETH": "\u{D0}", "ETH;": "\u{D0}",
        "Eacute": "\u{C9}", "Eacute;": "\u{C9}", "Ecirc": "\u{CA}", "Ecirc;": "\u{CA}", "Egrave": "\u{C8}",
        "Egrave;": "\u{C8}", "Epsilon;": "\u{395}", "Eta;": "\u{397}", "Euml": "\u{CB}", "Euml;": "\u{CB}",
        "GT": ">", "Gamma;": "\u{393}", "Iacute": "\u{CD}", "Iacute;": "\u{CD}", "Icirc": "\u{CE}",
        "Icirc;": "\u{CE}", "Igrave": "\u{CC}", "Igrave;": "\u{CC}", "Iota;": "\u{399}", "Iuml": "\u{CF}",
        "Iuml;": "\u{CF}", "Kappa;": "\u{39A}", "LT": "<", "Lambda;": "\u{39B}", "Mu;": "\u{39C}",
        "Ntilde": "\u{D1}", "Ntilde;": "\u{D1}", "Nu;": "\u{39D}", "OElig;": "\u{152}", "Oacute": "\u{D3}",
        "Oacute;": "\u{D3}", "Ocirc": "\u{D4}", "Ocirc;": "\u{D4}", "Ograve": "\u{D2}", "Ograve;": "\u{D2}",
        "Omega;": "\u{3A9}", "Omicron;": "\u{39F}", "Oslash": "\u{D8}", "Oslash;": "\u{D8}", "Otilde": "\u{D5}",
        "Otilde;": "\u{D5}", "Ouml": "\u{D6}", "Ouml;": "\u{D6}", "Phi;": "\u{3A6}", "Pi;": "\u{3A0}",
        "Prime;": "\u{2033}", "Psi;": "\u{3A8}", "QUOT": "\"", "REG": "\u{AE}", "Rho;": "\u{3A1}",
        "Scaron;": "\u{160}", "Sigma;": "\u{3A3}", "THORN": "\u{DE}", "THORN;": "\u{DE}", "Tau;": "\u{3A4}",
        "Theta;": "\u{398}", "Uacute": "\u{DA}", "Uacute;": "\u{DA}", "Ucirc": "\u{DB}", "Ucirc;": "\u{DB}",
        "Ugrave": "\u{D9}", "Ugrave;": "\u{D9}", "Upsilon;": "\u{3A5}", "Uuml": "\u{DC}", "Uuml;": "\u{DC}",
        "Xi;": "\u{39E}", "Yacute": "\u{DD}", "Yacute;": "\u{DD}", "Yuml;": "\u{178}", "Zeta;": "\u{396}",
        "aacute": "\u{E1}", "aacute;": "\u{E1}", "acirc": "\u{E2}", "acirc;": "\u{E2}", "acute": "\u{B4}",
        "acute;": "\u{B4}", "aelig": "\u{E6}", "aelig;": "\u{E6}", "agrave": "\u{E0}", "agrave;": "\u{E0}",
        "alefsym;": "\u{2135}", "alpha;": "\u{3B1}", "amp": "&", "amp;": "&", "and;": "\u{2227}",
        "ang;": "\u{2220}", "aring": "\u{E5}", "aring;": "\u{E5}", "asymp;": "\u{2248}", "atilde": "\u{E3}",
        "atilde;": "\u{E3}", "auml": "\u{E4}", "auml;": "\u{E4}", "bdquo;": "\u{201E}", "beta;": "\u{3B2}",
        "brvbar": "\u{A6}", "brvbar;": "\u{A6}", "bull;": "\u{2022}", "cap;": "\u{2229}", "ccedil": "\u{E7}",
        "ccedil;": "\u{E7}", "cedil": "\u{B8}", "cedil;": "\u{B8}", "cent": "\u{A2}", "cent;": "\u{A2}",
        "chi;": "\u{3C7}", "circ;": "\u{2C6}", "clubs;": "\u{2663}", "cong;": "\u{2245}", "copy": "\u{A9}",
        "copy;": "\u{A9}", "crarr;": "\u{21B5}", "cup;": "\u{222A}", "curren": "\u{A4}", "curren;": "\u{A4}",
        "dArr;": "\u{21D3}", "dagger;": "\u{2020}", "darr;": "\u{2193}", "deg": "\u{B0}", "deg;": "\u{B0}",
        "delta;": "\u{3B4}", "diams;": "\u{2666}", "divide": "\u{F7}", "divide;": "\u{F7}", "eacute": "\u{E9}",
        "eacute;": "\u{E9}", "ecirc": "\u{EA}", "ecirc;": "\u{EA}", "egrave": "\u{E8}", "egrave;": "\u{E8}",
        "empty;": "\u{2205}", "emsp;": "\u{2003}", "ensp;": "\u{2002}", "epsilon;": "\u{3B5}", "equiv;": "\u{2261}",
        "eta;": "\u{3B7}", "eth": "\u{F0}", "eth;": "\u{F0}", "euml": "\u{EB}", "euml;": "\u{EB}",
        "euro;": "\u{20AC}", "exist;": "\u{2203}", "fnof;": "\u{192}", "forall;": "\u{2200}", "frac12": "\u{BD}",
        "frac12;": "\u{BD}", "frac14": "\u{BC}", "frac14;": "\u{BC}", "frac34": "\u{BE}", "frac34;": "\u{BE}",
        "frasl;": "\u{2044}", "gamma;": "\u{3B3}", "ge;": "\u{2265}", "gt": ">", "gt;": ">", "hArr;": "\u{21D4}",
        "harr;": "\u{2194}", "hearts;": "\u{2665}", "hellip;": "\u{2026}", "iacute": "\u{ED}", "iacute;": "\u{ED}",
        "icirc": "\u{EE}", "icirc;": "\u{EE}", "iexcl": "\u{A1}", "iexcl;": "\u{A1}", "igrave": "\u{EC}",
        "igrave;": "\u{EC}", "image;": "\u{2111}", "infin;": "\u{221E}", "int;": "\u{222B}", "iota;": "\u{3B9}",
        "iquest": "\u{BF}", "iquest;": "\u{BF}", "isin;": "\u{2208}", "iuml": "\u{EF}", "iuml;": "\u{EF}",
        "kappa;": "\u{3BA}", "lArr;": "\u{21D0}", "lambda;": "\u{3BB}", "lang;": "\u{27E8}", "laquo": "\u{AB}",
        "laquo;": "\u{AB}", "larr;": "\u{2190}", "lceil;": "\u{2308}", "ldquo;": "\u{201C}", "le;": "\u{2264}",
        "lfloor;": "\u{230A}", "lowast;": "\u{2217}", "loz;": "\u{25CA}", "lrm;": "\u{200E}", "lsaquo;": "\u{2039}",
        "lsquo;": "\u{2018}", "lt": "<", "lt;": "<", "macr": "\u{AF}", "macr;": "\u{AF}", "mdash;": "\u{2014}",
        "micro": "\u{B5}", "micro;": "\u{B5}", "middot": "\u{B7}", "middot;": "\u{B7}", "minus;": "\u{2212}",
        "mu;": "\u{3BC}", "nabla;": "\u{2207}", "nbsp": "\u{A0}", "nbsp;": "\u{A0}", "ndash;": "\u{2013}",
        "ne;": "\u{2260}", "ni;": "\u{220B}", "not": "\u{AC}", "not;": "\u{AC}", "notin;": "\u{2209}",
        "nsub;": "\u{2284}", "ntilde": "\u{F1}", "ntilde;": "\u{F1}", "nu;": "\u{3BD}", "oacute": "\u{F3}",
        "oacute;": "\u{F3}", "ocirc": "\u{F4}", "ocirc;": "\u{F4}", "oelig;": "\u{153}", "ograve": "\u{F2}",
        "ograve;": "\u{F2}", "oline;": "\u{203E}", "omega;": "\u{3C9}", "omicron;": "\u{3BF}", "oplus;": "\u{2295}",
        "or;": "\u{2228}", "ordf": "\u{AA}", "ordf;": "\u{AA}", "ordm": "\u{BA}", "ordm;": "\u{BA}",
        "oslash": "\u{F8}", "oslash;": "\u{F8}", "otilde": "\u{F5}", "otilde;": "\u{F5}", "otimes;": "\u{2297}",
        "ouml": "\u{F6}", "ouml;": "\u{F6}", "para": "\u{B6}", "para;": "\u{B6}", "part;": "\u{2202}",
        "permil;": "\u{2030}", "perp;": "\u{22A5}", "phi;": "\u{3C6}", "pi;": "\u{3C0}", "piv;": "\u{3D6}",
        "plusmn": "\u{B1}", "plusmn;": "\u{B1}", "pound": "\u{A3}", "pound;": "\u{A3}", "prime;": "\u{2032}",
        "prod;": "\u{220F}", "prop;": "\u{221D}", "psi;": "\u{3C8}", "quot": "\"", "quot;": "\"",
        "rArr;": "\u{21D2}", "radic;": "\u{221A}", "rang;": "\u{27E9}", "raquo": "\u{BB}", "raquo;": "\u{BB}",
        "rarr;": "\u{2192}", "rceil;": "\u{2309}", "rdquo;": "\u{201D}", "real;": "\u{211C}", "reg": "\u{AE}",
        "reg;": "\u{AE}", "rfloor;": "\u{230B}", "rho;": "\u{3C1}", "rlm;": "\u{200F}", "rsaquo;": "\u{203A}",
        "rsquo;": "\u{2019}", "sbquo;": "\u{201A}", "scaron;": "\u{161}", "sdot;": "\u{22C5}", "sect": "\u{A7}",
        "sect;": "\u{A7}", "shy": "\u{AD}", "shy;": "\u{AD}", "sigma;": "\u{3C3}", "sigmaf;": "\u{3C2}",
        "sim;": "\u{223C}", "spades;": "\u{2660}", "sub;": "\u{2282}", "sube;": "\u{2286}", "sum;": "\u{2211}",
        "sup1": "\u{B9}", "sup1;": "\u{B9}", "sup2": "\u{B2}", "sup2;": "\u{B2}", "sup3": "\u{B3}",
        "sup3;": "\u{B3}", "sup;": "\u{2283}", "supe;": "\u{2287}", "szlig": "\u{DF}", "szlig;": "\u{DF}",
        "tau;": "\u{3C4}", "there4;": "\u{2234}", "theta;": "\u{3B8}", "thetasym;": "\u{3D1}",
        "thinsp;": "\u{2009}", "thorn": "\u{FE}", "thorn;": "\u{FE}", "tilde;": "\u{2DC}", "times": "\u{D7}",
        "times;": "\u{D7}", "trade;": "\u{2122}", "uArr;": "\u{21D1}", "uacute": "\u{FA}", "uacute;": "\u{FA}",
        "uarr;": "\u{2191}", "ucirc": "\u{FB}", "ucirc;": "\u{FB}", "ugrave": "\u{F9}", "ugrave;": "\u{F9}",
        "uml": "\u{A8}", "uml;": "\u{A8}", "upsih;": "\u{3D2}", "upsilon;": "\u{3C5}", "uuml": "\u{FC}",
        "uuml;": "\u{FC}", "weierp;": "\u{2118}", "xi;": "\u{3BE}", "yacute": "\u{FD}", "yacute;": "\u{FD}",
        "yen": "\u{A5}", "yen;": "\u{A5}", "yuml": "\u{FF}", "yuml;": "\u{FF}", "zeta;": "\u{3B6}",
        "zwj;": "\u{200D}", "zwnj;": "\u{200C}"
    ]
}

/// Python's `str.strip()` with no arguments: the characters `str.isspace()` accepts, which include
/// the ASCII separators 0x1C-0x1F and a few that `CharacterSet.whitespacesAndNewlines` treats
/// differently.
nonisolated enum PythonText {
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }
}
