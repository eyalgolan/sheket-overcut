import Foundation

/// One SMS keyword from `sms_keywords` (spec section 6.1).
public struct Keyword: Equatable {
    /// How much a keyword counts: one `strong` keyword, or two distinct
    /// `weak` keywords, send a message to Junk.
    public enum Strength: String, Equatable {
        case strong
        case weak
    }

    /// The keyword text, already normalised in the published list.
    public let text: String
    public let strength: Strength

    public init(text: String, strength: Strength) {
        self.text = text
        self.strength = strength
    }
}

/// A blocklist document, schema 1 (spec section 6.1,
/// `contract/blocklist.schema.json`).
public struct Blocklist: Equatable {
    /// Generation time in Unix seconds. Only increases.
    public let version: Int64
    /// RFC 3339 date-time, kept as written.
    public let generatedAt: String
    public let callNumbers: [String]
    public let callPrefixes: [String]
    /// E.164 numbers or sender IDs, stored as written.
    public let smsSenders: [String]
    public let smsKeywords: [Keyword]
    /// E.164 numbers or sender IDs, stored as written.
    public let smsAllowSenders: [String]

    public init(
        version: Int64,
        generatedAt: String,
        callNumbers: [String],
        callPrefixes: [String],
        smsSenders: [String],
        smsKeywords: [Keyword],
        smsAllowSenders: [String]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.callNumbers = callNumbers
        self.callPrefixes = callPrefixes
        self.smsSenders = smsSenders
        self.smsKeywords = smsKeywords
        self.smsAllowSenders = smsAllowSenders
    }
}

/// Why a blocklist document was rejected.
public enum BlocklistError: Error, Equatable {
    /// `field` names the failing key: `"root"` for a document that is not a
    /// JSON object or has an unknown key, otherwise the top-level key, or
    /// `"sms_keywords.text"` / `"sms_keywords.strength"` inside a keyword.
    case invalid(field: String)
}

/// Strict decoder for `contract/blocklist.schema.json`.
///
/// Any violation throws and no partial result is returned: per spec section 7
/// a malformed or wrong-schema list is "rejected whole; previous list kept",
/// so the caller keeps the list it already holds.
///
/// This uses `JSONSerialization` rather than `Codable` because `Codable`
/// cannot enforce the schema exactly: it silently ignores unknown keys
/// (the schema has `additionalProperties: false` at the top level and in each
/// keyword), and `Int64` decoding is lenient about JSON booleans and numbers
/// such as `1.0` that are not integers. Working on the raw `NSNumber` lets us
/// reject those.
public enum BlocklistDecoder {
    /// The schema's `required` keys, in the schema's order. Missing keys are
    /// reported in this order so the error is deterministic.
    private static let requiredKeys = [
        "schema",
        "version",
        "generated_at",
        "call_numbers",
        "call_prefixes",
        "sms_senders",
        "sms_keywords",
        "sms_allow_senders",
    ]

    public static func decode(_ data: Data) throws -> Blocklist {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BlocklistError.invalid(field: "root")
        }
        guard let root = object as? [String: Any] else {
            throw BlocklistError.invalid(field: "root")
        }
        for key in requiredKeys where root[key] == nil {
            throw BlocklistError.invalid(field: key)
        }
        // All required keys are present, so any further key is extra.
        guard root.count == requiredKeys.count else {
            throw BlocklistError.invalid(field: "root")
        }

        guard let schema = integer(root["schema"]), schema == 1 else {
            throw BlocklistError.invalid(field: "schema")
        }
        guard let version = integer(root["version"]) else {
            throw BlocklistError.invalid(field: "version")
        }
        guard let generatedAt = root["generated_at"] as? String,
              isRFC3339DateTime(generatedAt) else {
            throw BlocklistError.invalid(field: "generated_at")
        }
        let callNumbers = try strings(root["call_numbers"], field: "call_numbers",
                                      where: SenderNormalizer.isE164)
        let callPrefixes = try strings(root["call_prefixes"], field: "call_prefixes",
                                       where: isCallPrefix)
        let smsSenders = try strings(root["sms_senders"], field: "sms_senders",
                                     where: { !$0.isEmpty })
        let smsKeywords = try keywords(root["sms_keywords"])
        let smsAllowSenders = try strings(root["sms_allow_senders"], field: "sms_allow_senders",
                                          where: { !$0.isEmpty })

        return Blocklist(
            version: version,
            generatedAt: generatedAt,
            callNumbers: callNumbers,
            callPrefixes: callPrefixes,
            smsSenders: smsSenders,
            smsKeywords: smsKeywords,
            smsAllowSenders: smsAllowSenders
        )
    }

    // MARK: - Integers

    /// Returns the value as `Int64` if it is a JSON integer that fits.
    ///
    /// `as? Int` is never used: bridging would let `true` and `1.0` through.
    /// Rejected: booleans, floating-point numbers (including `1.0`), every
    /// `NSDecimalNumber`, and integers outside `Int64` (which
    /// `JSONSerialization` stores as an unsigned 64-bit value, a double or an
    /// `NSDecimalNumber`). An integer that fits in `Int64` always comes back
    /// as a plain integer `CFNumber`, so a decimal is never a valid integer
    /// here, and `1.0` is rejected whatever its parsed representation.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        // Checked before any CFNumber call: NSDecimalNumber is not a CFNumber.
        if number is NSDecimalNumber { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID(),
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number as CFNumber) else { return nil }
        return Int64(exactly: number)
    }

    // MARK: - Arrays

    /// Returns the value as an array of strings, each accepted by `isValid`,
    /// or throws `.invalid(field:)`.
    private static func strings(
        _ value: Any?,
        field: String,
        where isValid: (String) -> Bool
    ) throws -> [String] {
        guard let items = value as? [Any] else {
            throw BlocklistError.invalid(field: field)
        }
        var result: [String] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let s = item as? String, isValid(s) else {
                throw BlocklistError.invalid(field: field)
            }
            result.append(s)
        }
        return result
    }

    private static func keywords(_ value: Any?) throws -> [Keyword] {
        guard let items = value as? [Any] else {
            throw BlocklistError.invalid(field: "sms_keywords")
        }
        var result: [Keyword] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let object = item as? [String: Any],
                  object.count == 2,
                  let rawText = object["text"],
                  let rawStrength = object["strength"] else {
                throw BlocklistError.invalid(field: "sms_keywords")
            }
            guard let text = rawText as? String, !text.isEmpty else {
                throw BlocklistError.invalid(field: "sms_keywords.text")
            }
            guard let strengthName = rawStrength as? String,
                  let strength = Keyword.Strength(rawValue: strengthName) else {
                throw BlocklistError.invalid(field: "sms_keywords.strength")
            }
            result.append(Keyword(text: text, strength: strength))
        }
        return result
    }

    // MARK: - Patterns (ASCII scans, no regular expressions)

    private static func isDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39 // "0"..."9"
    }

    /// `^\+[1-9][0-9]{3,13}$`.
    private static func isCallPrefix(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count >= 5, bytes.count <= 15,
              bytes[0] == 0x2B, // "+"
              bytes[1] >= 0x31, bytes[1] <= 0x39 else { return false } // "1"..."9"
        return bytes[2...].allSatisfy(isDigit)
    }

    /// RFC 3339 `date-time`, as `rfc3339-validator` checks it:
    /// `YYYY-MM-DD` `T|t` `HH:MM:SS` [`.` 1+ digits] `Z|z|+HH:MM|-HH:MM`,
    /// with month, day (Gregorian leap years), hour, minute, second and
    /// offset ranges checked. Nothing may follow the offset.
    private static func isRFC3339DateTime(_ s: String) -> Bool {
        let b = Array(s.utf8)
        var i = 0

        /// Reads `count` ASCII digits at `i` as a number and advances `i`.
        func number(_ count: Int) -> Int? {
            guard i + count <= b.count else { return nil }
            var n = 0
            for _ in 0..<count {
                guard isDigit(b[i]) else { return nil }
                n = n * 10 + Int(b[i] - 0x30)
                i += 1
            }
            return n
        }
        /// Consumes `byte` at `i` if present.
        func expect(_ byte: UInt8) -> Bool {
            guard i < b.count, b[i] == byte else { return false }
            i += 1
            return true
        }

        guard let year = number(4), expect(0x2D), // "-"
              let month = number(2), expect(0x2D),
              let day = number(2) else { return false }
        guard i < b.count, b[i] == 0x54 || b[i] == 0x74 else { return false } // "T" or "t"
        i += 1
        guard let hour = number(2), expect(0x3A), // ":"
              let minute = number(2), expect(0x3A),
              let second = number(2) else { return false }

        if expect(0x2E) { // "."
            guard i < b.count, isDigit(b[i]) else { return false }
            while i < b.count, isDigit(b[i]) { i += 1 }
        }

        guard i < b.count else { return false }
        switch b[i] {
        case 0x5A, 0x7A: // "Z", "z"
            i += 1
        case 0x2B, 0x2D: // "+", "-"
            i += 1
            guard let offsetHour = number(2), expect(0x3A),
                  let offsetMinute = number(2),
                  offsetHour <= 23, offsetMinute <= 59 else { return false }
        default:
            return false
        }
        guard i == b.count else { return false }

        guard (1...12).contains(month) else { return false }
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth: Int
        switch month {
        case 2: daysInMonth = isLeap ? 29 : 28
        case 4, 6, 9, 11: daysInMonth = 30
        default: daysInMonth = 31
        }
        return (1...daysInMonth).contains(day)
            && hour <= 23 && minute <= 59 && second <= 59
    }
}
