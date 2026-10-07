import Foundation

/// Shared sender normaliser, a rule-by-rule port of `normalize_sender` and
/// `is_e164` in `backend/src/sheket/normalize.py`, applying the rules in the
/// same order.
///
/// The binding definition is spec section 6 (`docs/spec.md`) and
/// `contract/README.md`; the `normalize` cases in `contract/corpus.json` make
/// it executable. Rule changes wait on issue #12; do not change the rules here
/// without changing the backend and the contract first.
///
/// All matching works on Unicode scalars, never on `Character`: a space
/// followed by a combining mark is one `Character`, but Python's `str.strip()`
/// still removes the space. Digits are ASCII `0`-`9` only, as in the Python
/// patterns. No `NSRegularExpression` is used, because an anchored ICU `$`
/// also accepts a trailing newline.
///
/// Risk (design "Risks"): sender IDs are folded with
/// `folding(options: .caseInsensitive, locale: nil)` as the decided equivalent
/// of Python's `str.casefold()`. If that folding does not turn `ß` into `ss`,
/// it must be replaced by a scalar-level fold that matches `str.casefold()`.
public enum SenderNormalizer {
    /// Maximum sender ID length in Unicode scalars, measured after folding.
    private static let maxSenderIDLength = 20

    /// Returns true only for a string that fully matches `^\+[1-9][0-9]{6,14}$`
    /// (Python `E164`, which must equal `call_numbers.items.pattern` in
    /// `contract/blocklist.schema.json`).
    public static func isE164(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count >= 8, u.count <= 16, u[0] == "+", isNonZeroDigit(u[1]) else {
            return false
        }
        return isDigitRun(u[2...], length: 6...14)
    }

    /// Normalises a raw sender; returns the normalised form or nil.
    ///
    /// Rules, in order (see `normalize_sender` in
    /// `backend/src/sheket/normalize.py`):
    ///
    /// 1. Trim Python `str.isspace()` characters from both ends; empty
    ///    returns nil.
    /// 2. Phone-like input (an optional leading `+`, then only ASCII digits,
    ///    space, `(`, `)` and `-`): remove the separators; no digits returns
    ///    nil. A leading `+` or `972` plus 8-9 digits gives `+digits`; `0[1-9]`
    ///    plus 7-8 digits gives `+972` plus the digits without the leading 0;
    ///    3-5 digits with no leading 0 is a short number returned as digits;
    ///    anything else returns nil. A `+` result must pass `isE164`.
    /// 3. Star code: `*` followed by 2-6 ASCII digits, kept as written.
    /// 4. Anything else is a sender ID, case-folded; longer than 20 scalars
    ///    after folding, or containing any `str.isspace()` character, returns
    ///    nil.
    public static func normalize(_ raw: String) -> String? {
        // Rule 1: trim, like Python str.strip().
        let all = Array(raw.unicodeScalars)
        guard let start = all.firstIndex(where: { !isPySpace($0) }),
              let end = all.lastIndex(where: { !isPySpace($0) }) else {
            return nil
        }
        let scalars = all[start...end]

        // Rule 2: phone-like input, full match of \+?[0-9 ()\-]*.
        let hadPlus = scalars.first == "+"
        let body = hadPlus ? scalars.dropFirst() : scalars
        if body.allSatisfy({ isASCIIDigit($0) || $0 == " " || $0 == "(" || $0 == ")" || $0 == "-" }) {
            let digits = Array(body.filter { isASCIIDigit($0) })
            if digits.isEmpty {
                return nil
            }
            var candidate = String.UnicodeScalarView()
            if hadPlus || isILInternational(digits) {
                candidate.append("+")
                candidate.append(contentsOf: digits)
            } else if isILNational(digits) {
                candidate.append(contentsOf: "+972".unicodeScalars)
                candidate.append(contentsOf: digits.dropFirst())
            } else if isShortNumber(digits) {
                return String(String.UnicodeScalarView(digits))
            } else {
                return nil
            }
            let result = String(candidate)
            return isE164(result) ? result : nil
        }

        let s = String(String.UnicodeScalarView(scalars))

        // Rule 3: star code, full match of \*[0-9]{2,6}.
        if scalars.first == "*" && isDigitRun(scalars.dropFirst(), length: 2...6) {
            return s
        }

        // Rule 4: sender ID.
        let f = s.folding(options: .caseInsensitive, locale: nil)
        if f.unicodeScalars.count > maxSenderIDLength {
            return nil
        }
        if f.unicodeScalars.contains(where: { isPySpace($0) }) {
            return nil
        }
        return f
    }

    // MARK: - Private helpers

    /// Exactly Python `str.isspace()`.
    private static func isPySpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// ASCII `0`-`9` only (Python pattern `[0-9]`).
    private static func isASCIIDigit(_ u: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(u.value)
    }

    /// ASCII `1`-`9` (Python pattern `[1-9]`).
    private static func isNonZeroDigit(_ u: Unicode.Scalar) -> Bool {
        (0x31...0x39).contains(u.value)
    }

    /// Full match of `[0-9]{n,m}` where `length` is `n...m`.
    private static func isDigitRun(_ s: ArraySlice<Unicode.Scalar>, length: ClosedRange<Int>) -> Bool {
        length.contains(s.count) && s.allSatisfy { isASCIIDigit($0) }
    }

    /// Full match of `972[0-9]{8,9}`.
    private static func isILInternational(_ d: [Unicode.Scalar]) -> Bool {
        d.starts(with: "972".unicodeScalars) && isDigitRun(d.dropFirst(3), length: 8...9)
    }

    /// Full match of `0[1-9][0-9]{7,8}`.
    private static func isILNational(_ d: [Unicode.Scalar]) -> Bool {
        d.count >= 2 && d[0] == "0" && isNonZeroDigit(d[1]) && isDigitRun(d.dropFirst(2), length: 7...8)
    }

    /// Full match of `[1-9][0-9]{2,4}`.
    private static func isShortNumber(_ d: [Unicode.Scalar]) -> Bool {
        d.count >= 1 && isNonZeroDigit(d[0]) && isDigitRun(d.dropFirst(), length: 2...4)
    }
}
