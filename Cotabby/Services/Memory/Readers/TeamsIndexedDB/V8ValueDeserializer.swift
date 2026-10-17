import Foundation

/// File overview:
/// Turns the bytes Chromium stores for an IndexedDB value back into a JavaScript-like value tree.
///
/// Why it exists: a web app's IndexedDB values are JavaScript objects written with V8's structured
/// clone ("ValueSerializer", https://github.com/v8/v8/blob/main/src/objects/value-serializer.cc),
/// with Blink adding its own "host objects" (blobs, files, crypto keys) through an escape tag. Teams
/// stores every chat, message and profile this way, so reading its cache means reading this format.
/// It is separate from `IndexedDBReader` (which finds the bytes) because it is a self-contained
/// grammar with its own failure modes, tested on its own.
///
/// The format: a version header (`0xFF`, varint), then one value, each starting with a one-byte
/// tag: oddballs (`_` undefined, `0` null, `T`/`F`), numbers (`I` zigzag int32, `U` uint32, `N`
/// double, `Z` BigInt), strings (`"` Latin-1, `c` UTF-16LE, `S` UTF-8), containers (`o`...`{` object,
/// `A`...`$` dense array, `a`...`@` sparse array, `;`...`:` Map, `'`...`,` Set), `D` Date, wrapped
/// primitives (`y`, `x`, `n`, `z`, `s`), array buffers (`B`, optionally followed by a `V` view),
/// `\` Blink host objects, and `^` a back-reference to an object read earlier (V8 writes an object
/// reachable twice only once). `0x00` is padding and is skipped wherever a tag is expected.
///
/// What it produces: only what memory needs is kept with meaning (strings, numbers, booleans, null,
/// undefined, dates, arrays and objects; a Map becomes an object with string keys, a Set an array,
/// a wrapped primitive its primitive). Binary payloads (array buffers, typed arrays, blobs, files,
/// crypto keys) are consumed with their exact lengths and become `.opaque`, so the rest of the value
/// still decodes. Object keys keep their serialized order, as a JavaScript object does.
///
/// Defensive by construction: every length is checked against the input, recursion is bounded, a
/// back-reference to an object still being read (a cycle) yields `.undefined` instead of looping,
/// and anything malformed or unsupported throws `DeserializeError`; nothing here can trap.
///
/// Ported from CCL Forensics' `ccl_v8_value_deserializer` and `ccl_blink_value_deserializer` (MIT,
/// see THIRD_PARTY_LICENSES.md). Two deliberate differences from that port, both following V8:
/// a Latin-1 string with characters above 0x7F decodes to its text (the port returned raw bytes,
/// which the Teams mapping then treated as missing, so every message with an "ü" or "é" and no
/// character beyond Latin-1 was dropped), and an array buffer view takes an object id (the port
/// skipped it, shifting later back-references).
nonisolated indirect enum V8Value: Equatable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    /// Milliseconds since 1970, as JavaScript's `Date` holds it.
    case date(Double)
    case array([V8Value])
    case object(V8Object)
    /// A value with no meaning for memory (binary data, blobs, files, keys), read and skipped.
    case opaque

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var object: V8Object? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The value as plain Foundation types, the shape `TeamsMessageMapper` consumes: `String`,
    /// `Double`, `Bool`, `Date`, `[Any]`, `[String: Any]`, and `NSNull` for null, undefined and
    /// opaque values.
    var plainValue: Any {
        switch self {
        case .undefined, .null, .opaque: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .date(let milliseconds): return Date(timeIntervalSince1970: milliseconds / 1000)
        case .array(let values): return values.map(\.plainValue)
        case .object(let object): return object.plainDictionary
        }
    }
}

/// A JavaScript object's own properties, in the order they were serialized (Swift dictionaries do
/// not keep order, and the Teams mapping's tie-breaks depend on it).
nonisolated struct V8Object: Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: V8Value] = [:]

    init() {}

    init(_ pairs: [(String, V8Value)]) {
        for (key, value) in pairs { self[key] = value }
    }

    var count: Int { keys.count }

    /// The values in property order.
    var values: [V8Value] { keys.compactMap { storage[$0] } }

    /// Setting an existing key replaces its value and keeps its position, as in JavaScript.
    subscript(key: String) -> V8Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                if storage.removeValue(forKey: key) != nil { keys.removeAll { $0 == key } }
                return
            }
            if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
        }
    }

    var plainDictionary: [String: Any] {
        storage.mapValues(\.plainValue)
    }
}

nonisolated struct V8ValueDeserializer {
    enum DeserializeError: Error, Equatable {
        case truncated
        case missingVersion
        case unknownTag(UInt8)
        case unsupported(String)
        case malformed(String)
        case tooDeep
    }

    /// Deeper nesting than this is treated as malformed: real values are a few levels deep, and the
    /// bound keeps a hostile value from exhausting a background thread's stack.
    static let maximumDepth = 200

    private var reader: ByteReader
    private(set) var version: UInt32 = 0
    /// Objects by id, in the order V8 assigned ids. `nil` marks one still being read.
    private var objects: [V8Value?] = []
    private var arrayBufferIDs: Set<Int> = []
    private var depth = 0

    /// Decodes one serialized value (starting at its `0xFF` version header).
    static func deserialize(_ bytes: ArraySlice<UInt8>) throws -> V8Value {
        var deserializer = V8ValueDeserializer(reader: ByteReader(bytes))
        try deserializer.readHeader()
        return try deserializer.readObject()
    }

    private init(reader: ByteReader) {
        self.reader = reader
    }

    // MARK: - Primitives

    private mutating func readHeader() throws {
        guard try readTag() == 0xFF else { throw DeserializeError.missingVersion }
        version = try varint32()
    }

    /// The next tag, skipping padding.
    private mutating func readTag() throws -> UInt8 {
        while let byte = reader.readByte() {
            if byte != 0x00 { return byte }
        }
        throw DeserializeError.truncated
    }

    private func peekTag() -> UInt8? {
        var copy = reader
        while let byte = copy.readByte() {
            if byte != 0x00 { return byte }
        }
        return nil
    }

    private mutating func varint32() throws -> UInt32 {
        guard let value = reader.readVarint64(), value <= UInt64(UInt32.max) else { throw DeserializeError.truncated }
        return UInt32(value)
    }

    private mutating func varint64() throws -> UInt64 {
        guard let value = reader.readVarint64() else { throw DeserializeError.truncated }
        return value
    }

    private mutating func double() throws -> Double {
        guard let value = reader.readDoubleLE() else { throw DeserializeError.truncated }
        return value
    }

    private mutating func bytes(_ count: UInt32) throws -> ArraySlice<UInt8> {
        guard let value = reader.read(Int(count)) else { throw DeserializeError.truncated }
        return value
    }

    private mutating func latin1String() throws -> V8Value {
        let raw = try bytes(try varint32())
        if raw.allSatisfy({ $0 < 0x80 }) { return .string(String(lossyUTF8: raw)) }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.map { Unicode.Scalar($0) })
        return .string(String(scalars))
    }

    private mutating func utf8String() throws -> String {
        String(lossyUTF8: try bytes(try varint32()))
    }

    private mutating func twoByteString() throws -> String {
        let length = try varint32()
        guard length % 2 == 0 else { throw DeserializeError.malformed("odd two-byte string length") }
        let raw = try bytes(length)
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        var index = raw.startIndex
        while index < raw.endIndex {
            units.append(UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A BigInt: a bitfield (sign in bit 0, digit byte length above it) and little-endian digits.
    /// Kept as a number, which is what the mapping reads.
    private mutating func bigInt() throws -> Double {
        let bitfield = try varint32()
        let raw = try bytes((bitfield >> 1) & 0x3FFF_FFFF)
        let magnitude = raw.reversed().reduce(0.0) { $0 * 256 + Double($1) }
        return bitfield & 1 == 1 ? -magnitude : magnitude
    }

    /// Strings inside wrappers and errors: since version 12 a full value that must be a string.
    private mutating func wrappedString() throws -> String {
        if version < 12 { return try utf8String() }
        guard case .string(let value) = try readObject() else { throw DeserializeError.malformed("expected a string") }
        return value
    }

    // MARK: - Objects

    /// Reserves the next object id; the value is filled in by `complete` once fully read, so a
    /// back-reference to it from inside itself (a cycle) can be recognized.
    private mutating func reserveID() -> Int {
        objects.append(nil)
        return objects.count - 1
    }

    private mutating func complete(_ id: Int, _ value: V8Value) -> V8Value {
        objects[id] = value
        return value
    }

    mutating func readObject() throws -> V8Value {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw DeserializeError.tooDeep }

        // One switch per family of tags, so each stays readable: plain values, strings and
        // containers, boxed primitives (which take an object id), then buffers, references and
        // host objects.
        let tag = try readTag()
        if let value = try readPrimitive(tag) { return value }
        if let value = try readStringOrContainer(tag) { return value }
        if let value = try readBoxedPrimitive(tag) { return value }
        if let value = try readBufferReferenceOrHostObject(tag) { return value }
        throw DeserializeError.unknownTag(tag)
    }

    private mutating func readPrimitive(_ tag: UInt8) throws -> V8Value? {
        switch tag {
        case UInt8(ascii: "?"): // kVerifyObjectCount: a legacy count, then the real value
            _ = try varint32()
            return try readObject()
        case UInt8(ascii: "_"), UInt8(ascii: "-"): return .undefined // undefined, the hole
        case UInt8(ascii: "0"): return .null
        case UInt8(ascii: "T"): return .bool(true)
        case UInt8(ascii: "F"): return .bool(false)
        case UInt8(ascii: "I"):
            let zigzag = try varint32()
            return .number(Double(Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))))
        case UInt8(ascii: "U"): return .number(Double(try varint32()))
        case UInt8(ascii: "N"): return .number(try double())
        case UInt8(ascii: "Z"): return .number(try bigInt())
        default: return nil
        }
    }

    private mutating func readStringOrContainer(_ tag: UInt8) throws -> V8Value? {
        switch tag {
        case UInt8(ascii: "\""): return try latin1String()
        case UInt8(ascii: "c"): return .string(try twoByteString())
        case UInt8(ascii: "S"): return .string(try utf8String())
        case UInt8(ascii: "o"): return try readJSObject()
        case UInt8(ascii: "A"): return try readDenseArray()
        case UInt8(ascii: "a"): return try readSparseArray()
        case UInt8(ascii: ";"): return try readMap()
        case UInt8(ascii: "'"): return try readSet()
        default: return nil
        }
    }

    private mutating func readBoxedPrimitive(_ tag: UInt8) throws -> V8Value? {
        switch tag {
        case UInt8(ascii: "D"):
            let id = reserveID()
            return complete(id, .date(try double()))
        case UInt8(ascii: "y"), UInt8(ascii: "x"):
            let id = reserveID()
            return complete(id, .bool(tag == UInt8(ascii: "y")))
        case UInt8(ascii: "n"):
            let id = reserveID()
            return complete(id, .number(try double()))
        case UInt8(ascii: "z"):
            let id = reserveID()
            return complete(id, .number(try bigInt()))
        case UInt8(ascii: "s"):
            let id = reserveID()
            return complete(id, .string(try wrappedString()))
        case UInt8(ascii: "R"):
            let id = reserveID()
            _ = try wrappedString() // pattern
            _ = try varint32() // flags
            return complete(id, .opaque)
        default: return nil
        }
    }

    private mutating func readBufferReferenceOrHostObject(_ tag: UInt8) throws -> V8Value? {
        switch tag {
        case UInt8(ascii: "^"):
            let id = Int(try varint32())
            guard id < objects.count else { throw DeserializeError.malformed("reference to an unknown object") }
            let value = objects[id] ?? .undefined
            if arrayBufferIDs.contains(id), peekTag() == UInt8(ascii: "V") {
                _ = try readTag()
                return try readArrayBufferView()
            }
            return value
        case UInt8(ascii: "B"):
            let id = reserveID()
            _ = try bytes(try varint32())
            arrayBufferIDs.insert(id)
            _ = complete(id, .opaque)
            if peekTag() == UInt8(ascii: "V") {
                _ = try readTag()
                return try readArrayBufferView()
            }
            return .opaque
        case UInt8(ascii: "t"), UInt8(ascii: "u"): // transferred / shared array buffer: an id only
            let id = reserveID()
            _ = try varint32()
            arrayBufferIDs.insert(id)
            return complete(id, .opaque)
        case UInt8(ascii: "r"): return try readError()
        case UInt8(ascii: "\\"):
            let id = reserveID()
            try skipBlinkHostObject()
            return complete(id, .opaque)
        default: return nil
        }
    }

    private mutating func readArrayBufferView() throws -> V8Value {
        let id = reserveID()
        _ = try varint32() // element type
        _ = try varint32() // byte offset
        _ = try varint32() // byte length
        if version >= 14 { _ = try varint32() } // flags
        return complete(id, .opaque)
    }

    /// Key/value pairs until `endTag`, as objects and arrays write their properties.
    private mutating func readProperties(until endTag: UInt8) throws -> [(String, V8Value)] {
        var pairs: [(String, V8Value)] = []
        while true {
            guard let next = peekTag() else { throw DeserializeError.truncated }
            if next == endTag {
                _ = try readTag()
                return pairs
            }
            let key = try Self.propertyKey(readObject())
            pairs.append((key, try readObject()))
        }
    }

    /// Object keys are strings, or numbers for integer-like keys (`{1: x}`).
    private static func propertyKey(_ value: V8Value) throws -> String {
        switch value {
        case .string(let key): return key
        case .number(let number):
            // Explicit types and `magnitude`, not `abs`: with Accelerate imported elsewhere in the
            // module, older compilers find `abs` ambiguous here.
            if number == number.rounded(), number.magnitude < 1e15 {
                let integer = Int64(number)
                return String(integer)
            }
            return String(describing: number)
        case .opaque:
            // A key that is neither text nor a number gets a name no lookup by name can match.
            return "\u{0}bytes"
        default: throw DeserializeError.malformed("unsupported property key")
        }
    }

    private mutating func readJSObject() throws -> V8Value {
        let id = reserveID()
        var object = V8Object()
        let pairs = try readProperties(until: UInt8(ascii: "{"))
        for (key, value) in pairs { object[key] = value }
        guard try varint32() == pairs.count else { throw DeserializeError.malformed("object property count") }
        return complete(id, .object(object))
    }

    private mutating func readDenseArray() throws -> V8Value {
        let id = reserveID()
        let length = Int(try varint32())
        // Each element takes at least one byte, so a longer claim is corrupt (and would otherwise
        // allocate whatever the length says).
        guard length <= reader.remaining else { throw DeserializeError.truncated }
        var elements: [V8Value] = []
        elements.reserveCapacity(length)
        for _ in 0..<length {
            elements.append(try readObject())
        }
        let extra = try readProperties(until: UInt8(ascii: "$"))
        Self.applyIndexedProperties(extra, to: &elements)
        guard try varint32() == extra.count else { throw DeserializeError.malformed("array property count") }
        _ = try varint32() // length again
        return complete(id, .array(elements))
    }

    private mutating func readSparseArray() throws -> V8Value {
        let id = reserveID()
        let length = Int(try varint32())
        let pairs = try readProperties(until: UInt8(ascii: "@"))
        // A sparse array can claim a huge length, and one element at index four billion would make
        // a dense copy of it allocate gigabytes from a few input bytes. Holes are only expanded
        // when the array is reasonably dense; otherwise its elements are kept in index order.
        var indexed: [(Int, V8Value)] = []
        for (key, value) in pairs {
            if let index = Int(key), index >= 0, index < length { indexed.append((index, value)) }
        }
        let highest = indexed.map(\.0).max()
        var elements: [V8Value]
        if let highest, highest >= Self.maximumSparseExpansion(elements: indexed.count) {
            elements = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        } else {
            elements = [V8Value](repeating: .undefined, count: highest.map { $0 + 1 } ?? 0)
            Self.applyIndexedProperties(pairs, to: &elements)
        }
        guard try varint32() == pairs.count else { throw DeserializeError.malformed("array property count") }
        _ = try varint32() // length again
        return complete(id, .array(elements))
    }

    /// The largest index a sparse array may be expanded to: generous for real arrays with a few
    /// holes, bounded for crafted ones.
    static func maximumSparseExpansion(elements: Int) -> Int {
        max(4096, elements * 16)
    }

    /// Index properties fill their slot; named properties on an array have no place in the value.
    private static func applyIndexedProperties(_ pairs: [(String, V8Value)], to elements: inout [V8Value]) {
        for (key, value) in pairs {
            if let index = Int(key), index >= 0, index < elements.count { elements[index] = value }
        }
    }

    private mutating func readMap() throws -> V8Value {
        let id = reserveID()
        var object = V8Object()
        var items = 0
        while true {
            guard let next = peekTag() else { throw DeserializeError.truncated }
            if next == UInt8(ascii: ":") {
                _ = try readTag()
                break
            }
            let key = try readObject()
            let value = try readObject()
            items += 2
            if let name = try? Self.propertyKey(key) { object[name] = value }
        }
        guard try varint32() == items else { throw DeserializeError.malformed("map length") }
        return complete(id, .object(object))
    }

    private mutating func readSet() throws -> V8Value {
        let id = reserveID()
        var elements: [V8Value] = []
        while true {
            guard let next = peekTag() else { throw DeserializeError.truncated }
            if next == UInt8(ascii: ",") {
                _ = try readTag()
                break
            }
            elements.append(try readObject())
        }
        guard try varint32() == elements.count else { throw DeserializeError.malformed("set length") }
        return complete(id, .array(elements))
    }

    /// An Error: subtags until `.`; the prototype tags carry no data, `m` and `s` a string, `c` a
    /// value (the cause).
    private mutating func readError() throws -> V8Value {
        let id = reserveID()
        var object = V8Object()
        while true {
            let subtag = try varint32()
            switch subtag {
            case UInt32(UInt8(ascii: ".")): return complete(id, .object(object))
            case UInt32(UInt8(ascii: "m")): object["message"] = .string(try wrappedString())
            case UInt32(UInt8(ascii: "s")): object["stack"] = .string(try wrappedString())
            case UInt32(UInt8(ascii: "c")): object["cause"] = try readObject()
            case UInt32(UInt8(ascii: "E")), UInt32(UInt8(ascii: "R")), UInt32(UInt8(ascii: "F")),
                 UInt32(UInt8(ascii: "S")), UInt32(UInt8(ascii: "T")), UInt32(UInt8(ascii: "U")):
                continue
            default:
                throw DeserializeError.malformed("unknown error subtag")
            }
        }
    }

    // MARK: - Blink host objects

    /// Consumes one Blink host object (third_party/blink/renderer/bindings/core/v8/serialization).
    /// Their payloads are references to blobs and files stored elsewhere, keys and geometry, none
    /// of which memory reads, but each must be skipped by its exact size for the rest to decode.
    /// The fixed payload size of a geometry host object (doubles), or nil for any other tag.
    private static func geometryHostObjectSize(_ tag: UInt8) -> UInt32? {
        switch tag {
        case UInt8(ascii: "Q"), UInt8(ascii: "W"), UInt8(ascii: "E"), UInt8(ascii: "R"): return 4 * 8 // point, rect
        case UInt8(ascii: "I"), UInt8(ascii: "O"): return 6 * 8 // 2D matrix
        case UInt8(ascii: "T"), UInt8(ascii: "Y"), UInt8(ascii: "U"): return 16 * 8 // quad (4 points), 4x4 matrix
        default: return nil
        }
    }

    private mutating func skipBlinkHostObject() throws {
        let tag = try bytes(1).first!
        if let size = Self.geometryHostObjectSize(tag) {
            _ = try bytes(size)
            return
        }
        switch tag {
        case UInt8(ascii: "i"), UInt8(ascii: "e"): // blob index, file index
            _ = try varint32()
        case UInt8(ascii: "L"): // file list index
            let count = try varint32()
            guard Int(count) <= reader.remaining else { throw DeserializeError.truncated }
            for _ in 0..<count { _ = try varint32() }
        case UInt8(ascii: "n"), UInt8(ascii: "N"): // file system file / directory handle
            _ = try utf8String()
            _ = try varint32()
        case UInt8(ascii: "b"): // blob: uuid, type, size
            _ = try utf8String()
            _ = try utf8String()
            _ = try varint64()
        case UInt8(ascii: "x"): // DOMException: name, message, stack
            _ = try utf8String()
            _ = try utf8String()
            _ = try utf8String()
        case UInt8(ascii: "K"):
            try skipCryptoKey()
        default:
            throw DeserializeError.unsupported("Blink host object \(tag)")
        }
    }

    /// A CryptoKey: subtype, its parameters, usages, then the key bytes.
    private mutating func skipCryptoKey() throws {
        let subtype = try bytes(1).first!
        switch subtype {
        case 1, 2: // AES: algorithm, length; HMAC: length, hash
            _ = try varint32()
            _ = try varint32()
        case 4: // RSA hashed: algorithm, type byte, modulus bits, exponent, hash
            _ = try varint32()
            _ = try bytes(1)
            _ = try varint32()
            _ = try bytes(try varint32())
            _ = try varint32()
        case 5: // EC: algorithm, type byte, named curve
            _ = try varint32()
            _ = try bytes(1)
            _ = try varint32()
        case 6: // no parameters: algorithm
            _ = try varint32()
        default:
            throw DeserializeError.unsupported("crypto key subtype \(subtype)")
        }
        _ = try varint32() // usages
        _ = try bytes(try varint32())
    }
}
