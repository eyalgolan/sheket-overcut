package app.sheket.ui

/**
 * The quiet "last updated" line on the status screen (spec 7): what, if
 * anything, it shows about the age of the blocklist.
 */
sealed interface StaleLine {

    /** The list is fresh enough, or there is nothing to measure from; no line is shown. */
    data object Hidden : StaleLine

    /** The list is stale; the line shows [atMillis] (epoch milliseconds), the time of the last success. */
    data class LastUpdated(val atMillis: Long) : StaleLine

    /** No check has ever succeeded and more than [STALE_AFTER_MS] has passed since `first_run_at`. */
    data object NeverUpdated : StaleLine
}

/** How old the list may get before the stale line is shown: 24 hours, in milliseconds. */
const val STALE_AFTER_MS: Long = 24L * 60 * 60 * 1000

/**
 * Decides the stale line at [nowMillis] (epoch milliseconds).
 *
 * This is the provisional answer to OQ-3 (Decision 5 on #6): age is measured
 * from [lastSuccessAt], the last successful check (a 200 or a 304), falling
 * back to [firstRunAt] when no check has succeeded yet. Because a 304 records
 * success, the line disappears right after one even though the list itself
 * did not change. "More than 24 hours" (spec 7) means strictly greater than
 * [STALE_AFTER_MS].
 *
 * Returns [StaleLine.Hidden] when neither time is known, when the baseline is
 * at most [STALE_AFTER_MS] old, or when it lies in the future (for example
 * after the clock was moved back).
 */
fun staleLine(nowMillis: Long, lastSuccessAt: Long?, firstRunAt: Long?): StaleLine {
    val baseline = lastSuccessAt ?: firstRunAt ?: return StaleLine.Hidden
    if (nowMillis - baseline <= STALE_AFTER_MS) return StaleLine.Hidden
    return if (lastSuccessAt != null) StaleLine.LastUpdated(lastSuccessAt) else StaleLine.NeverUpdated
}
