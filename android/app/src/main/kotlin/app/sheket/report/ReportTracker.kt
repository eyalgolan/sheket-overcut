package app.sheket.report

/**
 * App-scoped state of the reports the user starts from the report screen
 * (spec 6.2, 7). It outlives any one screen instance, so a report still in
 * flight across a rotation keeps its spinner, and its result is shown by
 * whichever instance is on screen when it arrives, or by the next one.
 *
 * Holds no `Activity`: screens attach with [addListener] while started and
 * detach with [removeListener].
 *
 * [pending], [lastOutcome] and the listeners are read and written on the main
 * thread only; [send] runs through [runInBackground] and its result is
 * delivered through [postToMain].
 */
class ReportTracker(
    private val send: (String) -> ReportOutcome,
    private val runInBackground: (Runnable) -> Unit,
    private val postToMain: (Runnable) -> Unit,
) {

    private val inFlight = mutableSetOf<String>()
    private val listeners = mutableListOf<(ReportOutcome) -> Unit>()

    /** Ids of the log entries whose report is in flight. */
    val pending: Set<String> get() = inFlight.toSet()

    /**
     * The newest result that was not [ReportOutcome.Refused], or null. Kept
     * until [clearLastOutcome], so a screen started after the result arrived
     * can still show it.
     */
    var lastOutcome: ReportOutcome? = null
        private set

    /**
     * Sends a report for [number], from the log entry [id]. Returns false,
     * and sends nothing, if a report for [id] is already in flight.
     */
    fun start(id: String, number: String): Boolean {
        if (!inFlight.add(id)) return false
        runInBackground(
            Runnable {
                val outcome = try {
                    send(number)
                } catch (e: Exception) {
                    ReportOutcome.NotSent()
                }
                postToMain(Runnable { finish(id, outcome) })
            },
        )
        return true
    }

    /** Forgets [lastOutcome], when the user leaves the report screen. */
    fun clearLastOutcome() {
        lastOutcome = null
    }

    fun addListener(listener: (ReportOutcome) -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: (ReportOutcome) -> Unit) {
        listeners -= listener
    }

    private fun finish(id: String, outcome: ReportOutcome) {
        inFlight -= id
        // Refused means no request was made; the earlier result stays.
        if (outcome != ReportOutcome.Refused) lastOutcome = outcome
        for (listener in listeners.toList()) listener(outcome)
    }
}
