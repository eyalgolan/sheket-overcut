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
}
