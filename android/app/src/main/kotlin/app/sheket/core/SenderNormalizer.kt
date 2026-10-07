package app.sheket.core

import java.util.Locale

/**
 * Shared sender normaliser: a rule-for-rule port of `normalize_sender` and
 * `is_e164` in `backend/src/sheket/normalize.py`. The binding definition is
 * spec section 6 and `contract/README.md`; the `normalize` cases in
 * `contract/corpus.json` make it executable.
 *
 * Every pattern uses ASCII `[0-9]` and is applied with [Regex.matches] (a full
 * match). Partial matching is never used, because `$` would also match before a
 * trailing line terminator.
 *
 * Known, deliberate behaviour:
 * - Sender IDs are folded with `lowercase(Locale.ROOT)` where Python uses
 *   `str.casefold()`. The two differ only for a few characters (for example
 *   `casefold()` turns sharp s, U+00DF, into `ss` and final sigma, U+03C2,
 *   into U+03C3). The app only blocks and reports calls, which are E.164
 *   numbers, so it never uses a sender ID for blocking or reporting and the
 *   difference cannot change an outcome.
 * - A `tel:` URI scheme is not stripped here; the caller strips it (#22).
 *   `"tel:0555001234"` is therefore a sender ID and comes back unchanged.
 * - `"+972 (0)55 500 1234"` keeps today's backend behaviour and gives
 *   `"+9720555001234"`, pending #12: `(0)` is not special.
 * - A non-numeric caller handle such as `"Unknown"` gives `"unknown"`, which is
 *   not E.164 and so is never blocked.
 */
object SenderNormalizer {

    /** Must equal `call_numbers.items.pattern` in `contract/blocklist.schema.json`. */
    val E164 = Regex("^\\+[1-9][0-9]{6,14}$")

    /**
     * Exactly the characters for which Python's `str.isspace()` is true (29 code
     * points, all in the BMP). Kotlin's built-in whitespace test is a different
     * set, so it is never used here.
     */
    val WHITESPACE: Set<Char> = buildSet {
        addAll('\u0009'..'\u000D')
        addAll('\u001C'..'\u001F')
        add('\u0020')
        add('\u0085')
        add('\u00A0')
        add('\u1680')
        addAll('\u2000'..'\u200A')
        add('\u2028')
        add('\u2029')
        add('\u202F')
        add('\u205F')
        add('\u3000')
    }

    private val PHONE_CHARS = Regex("\\+?[0-9 ()\\-]*")
    private val STAR_CODE = Regex("\\*[0-9]{2,6}")
    private val IL_INTERNATIONAL = Regex("972[0-9]{8,9}")

    // 0 then a non-zero digit: "00" is the international dialling prefix.
    private val IL_NATIONAL = Regex("0[1-9][0-9]{7,8}")
    private val SHORT_NUMBER = Regex("[1-9][0-9]{2,4}")
    private val SEPARATORS = Regex("[+ ()\\-]")
    private const val MAX_SENDER_ID_LEN = 20

    /** True only for a non-null string that fully matches [E164]. */
    fun isE164(s: String?): Boolean = s != null && E164.matches(s)

    /**
     * Normalises a raw sender; returns the normalised form, or null.
     *
     * Rules, in the order applied (same as the Python):
     * 1. Null returns null. Trim [WHITESPACE]; empty after trimming returns null.
     * 2. Phone-like input (optional leading `+`, then only ASCII digits, space,
     *    `(`, `)` and `-`): remove the separators; no digits left returns null.
     *    Then `+` digits are kept as written; `972` plus 8-9 digits becomes
     *    `+972...`; a national `0[1-9]` number becomes `+972` without the 0
     *    (`00...` returns null); 3-5 digits with no leading 0 is a short number
     *    returned as digits; anything else returns null. A `+`, `972` or national
     *    result must pass [isE164], or null is returned.
     * 3. Star code: `*` then 2-6 ASCII digits, kept as written.
     * 4. Anything else is a sender ID, lowercased with [Locale.ROOT].
     * 5. A sender ID longer than 20 code points after folding returns null.
     * 6. A sender ID containing any [WHITESPACE] character returns null.
     */
    fun normalize(raw: String?): String? {
        if (raw == null) return null
        val s = raw.trim { it in WHITESPACE }
        if (s.isEmpty()) return null

        if (PHONE_CHARS.matches(s)) {
            val hadPlus = s.startsWith("+")
            val digits = s.replace(SEPARATORS, "")
            if (digits.isEmpty()) return null
            val candidate = when {
                hadPlus || IL_INTERNATIONAL.matches(digits) -> "+$digits"
                IL_NATIONAL.matches(digits) -> "+972" + digits.substring(1)
                SHORT_NUMBER.matches(digits) -> return digits
                else -> return null
            }
            return if (isE164(candidate)) candidate else null
        }

        if (STAR_CODE.matches(s)) return s

        val f = s.lowercase(Locale.ROOT)
        if (f.codePointCount(0, f.length) > MAX_SENDER_ID_LEN) return null
        if (f.any { it in WHITESPACE }) return null
        return f
    }
}
