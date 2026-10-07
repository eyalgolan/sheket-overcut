package app.sheket.core

/**
 * Decides whether an incoming call is blocked (spec 6.1): the caller is
 * normalised with [SenderNormalizer], and only an E.164 result can match, either
 * exactly against `call_numbers` or by starting with one of `call_prefixes`.
 */
class CallMatcher(private val blocklist: Blocklist) {

    /**
     * True if [rawNumber] normalises to an E.164 number that is in
     * `call_numbers` or starts with an entry of `call_prefixes`. A withheld or
     * non-numeric caller (null, empty, `"Unknown"`) is never blocked.
     */
    fun shouldBlock(rawNumber: String?): Boolean {
        val n = SenderNormalizer.normalize(rawNumber)
        if (n == null || !SenderNormalizer.isE164(n)) return false
        if (n in blocklist.callNumbers) return true
        // A valid prefix is 5-15 characters long (BlocklistParser.CALL_PREFIX).
        for (len in 5..minOf(n.length, 15)) {
            if (n.substring(0, len) in blocklist.callPrefixes) return true
        }
        return false
    }
}
