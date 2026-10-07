import Foundation

// Turns a `Blocklist` into the exact Call Directory entries iOS installs
// (spec sections 4 and 6.1, `contract/README.md` "`test-blocklist.json`",
// design Phase 1.6, issue #17).
//
// The Call Directory extension blocks exact numbers only, supplied as `Int64`
// values (the E.164 digits without the `+`) in ascending order; it cannot
// match prefixes (spec section 4). So the entries are built as follows:
//
// 1. Every number in `call_numbers` comes first.
// 2. Then each prefix in `call_prefixes` is expanded into every full number
//    it covers, but only when it leaves between 0 and 4 free digits
//    (`0 <= 12 - digits <= 4`, where 12 is the digit count of an Israeli
//    mobile number and `digits` is the prefix's digit count). A prefix with
//    more free digits is skipped on iOS; Android still blocks it by prefix.
// 3. Duplicates are dropped, entries stop at 500,000 in total (spec 6.1,
//    `call_numbers` taken first), and the result is sorted ascending.
//
// `isBlocked` searches the built entries rather than matching prefixes, so
// the tests check exactly what iOS installs, including skipped prefixes and
// the cap, instead of a parallel prefix rule that could drift from it.

/// Why stored Call Directory entries were rejected.
public enum CallDirectoryEntriesError: Error, Equatable {
    /// The encoded entries are malformed, so they must not be handed to iOS.
    case corrupt
}

/// Builds and reads the Call Directory entries for a blocklist. See the
/// file-level documentation above for the rules.
public enum CallDirectoryEntries {
    /// Maximum number of Call Directory entries installed (spec 6.1).
    public static let defaultCap = 500_000

    /// Digit count of an Israeli mobile number in E.164, without the `+`
    /// (`+972` then 9 digits).
    private static let fullLength = 12

    /// Most free digits a prefix may leave and still be expanded on iOS
    /// (10,000 numbers, spec 6.1).
    private static let maxFreeDigits = 4

    /// `10^free` for `free` in `0...maxFreeDigits`, so no floating-point
    /// `pow` is needed.
    private static let powersOfTen: [Int64] = [1, 10, 100, 1_000, 10_000]

    /// Most digits `digits(_:)` accepts: 18 decimal digits always fit in
    /// `Int64`. The decoder already limits numbers to 15 digits, but
    /// `Blocklist`'s public initialiser does not go through the decoder.
    private static let maxDigits = 18

    /// Builds the Call Directory entries for `list`, sorted ascending.
    ///
    /// - Numbers first: every `callNumbers` entry, in document order, is
    ///   taken before any prefix is expanded (spec 6.1).
    /// - Distinct: duplicates and overlaps between numbers and prefixes are
    ///   counted once.
    /// - Exact cap: the result never holds more than `cap` entries. Building
    ///   stops as soon as `cap` distinct entries are held, even part-way
    ///   through a prefix. A `cap` of 0 or less returns an empty array.
    /// - Skipped prefixes: a prefix is expanded only when it leaves 0 to 4
    ///   free digits of a 12-digit number (so `+97255501` gives 10,000
    ///   entries, while `+9725552`, with 5 free digits, and `+1212`, with 8,
    ///   give none). Entries that are not `+`, then `1`-`9`, then ASCII
    ///   digits are ignored.
    public static func build(_ list: Blocklist, cap: Int = defaultCap) -> [Int64] {
        guard cap > 0 else { return [] }

        // Capacity estimate, kept <= cap so the additions cannot overflow.
        var estimate = min(cap, list.callNumbers.count)
        for prefix in list.callPrefixes {
            let free = fullLength - (prefix.utf8.count - 1)
            guard (0...maxFreeDigits).contains(free) else { continue }
            estimate += min(Int(powersOfTen[free]), cap - estimate)
        }
        var set = Set<Int64>()
        set.reserveCapacity(estimate)

        for number in list.callNumbers {
            if set.count == cap { return set.sorted() }
            if let value = digits(number) {
                set.insert(value)
            }
        }

        for prefix in list.callPrefixes {
            let free = fullLength - (prefix.utf8.count - 1)
            guard (0...maxFreeDigits).contains(free),
                  let p = digits(prefix) else { continue }
            // At most 12 digits in total, so none of this can overflow.
            let base = p * powersOfTen[free]
            for value in base..<(base + powersOfTen[free]) {
                if set.count == cap { return set.sorted() }
                set.insert(value)
            }
        }

        return set.sorted()
    }

    /// The digits after the `+` as an `Int64`, or nil unless `s` is `+`,
    /// then `1`-`9`, then ASCII digits only, with at most `maxDigits` digits.
    private static func digits(_ s: String) -> Int64? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 2, bytes.count - 1 <= maxDigits,
              bytes[0] == 0x2B, // "+"
              bytes[1] >= 0x31, bytes[1] <= 0x39 else { return nil } // "1"..."9"
        var value: Int64 = 0
        for b in bytes[1...] {
            guard b >= 0x30, b <= 0x39 else { return nil } // "0"..."9"
            value = value * 10 + Int64(b - 0x30)
        }
        return value
    }
}
