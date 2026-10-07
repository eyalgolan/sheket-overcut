package app.sheket.screening

import app.sheket.core.CallMatcher
import app.sheket.core.SenderNormalizer

/**
 * The outcome of screening one incoming call (#22).
 *
 * [number] is the caller's normalised E.164 form. It is null when the caller is
 * withheld, when the handle is not a `tel:` URI (for example `sip:`), or when
 * the number does not normalise to E.164.
 */
data class ScreeningDecision(val block: Boolean, val number: String?) {

    companion object {
        /** Let the call through, with no number recorded. */
        val ALLOW = ScreeningDecision(block = false, number = null)
    }
}

/**
 * Pure screening decision: no Android imports, so it can be unit tested on the
 * JVM. Matching rules live only in [CallMatcher]; this object never repeats them.
 */
object ScreeningDecider {

    /**
     * Decides whether to block a call from a handle with [scheme] and
     * [schemeSpecificPart] (Telecom has already URI-decoded the latter, and it
     * does not include the `tel:` prefix).
     *
     * - A scheme other than `tel` (case-insensitive; null and `sip` included)
     *   is allowed.
     * - A null [schemeSpecificPart] (withheld caller) is allowed.
     * - Otherwise the call is blocked if [CallMatcher.shouldBlock] says so.
     *
     * [matcher] is a supplier so that loading the blocklist, which may happen
     * in a cold process, also runs inside the guard: anything thrown, by the
     * supplier or by the decision itself, allows the call.
     */
    fun decide(
        scheme: String?,
        schemeSpecificPart: String?,
        matcher: () -> CallMatcher,
    ): ScreeningDecision = try {
        if (!"tel".equals(scheme, ignoreCase = true)) {
            ScreeningDecision.ALLOW
        } else {
            val raw = schemeSpecificPart
            if (raw == null) {
                ScreeningDecision.ALLOW
            } else {
                val number = SenderNormalizer.normalize(raw)
                    ?.takeIf { SenderNormalizer.isE164(it) }
                ScreeningDecision(block = matcher().shouldBlock(raw), number = number)
            }
        }
    } catch (e: Throwable) {
        ScreeningDecision.ALLOW
    }
}
