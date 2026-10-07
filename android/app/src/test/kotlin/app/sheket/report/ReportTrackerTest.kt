package app.sheket.report

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The app-scoped report state (#24, spec 6.2 and 7): a report in flight and
 * its result outlive the screen that started it, so a rotation neither
 * re-enables the row nor loses a "not sent" result.
 */
class ReportTrackerTest {

    private val background = ArrayDeque<Runnable>()
    private val main = ArrayDeque<Runnable>()
    private val sent = mutableListOf<String>()
    private var answer: (String) -> ReportOutcome = { ReportOutcome.Sent }

    private val tracker = ReportTracker(
        send = { number ->
            sent += number
            answer(number)
        },
        runInBackground = { background.addLast(it) },
        postToMain = { main.addLast(it) },
    )

    /** Runs the queued background work, then the results it posted. */
    private fun drain() {
        while (background.isNotEmpty()) background.removeFirst().run()
        while (main.isNotEmpty()) main.removeFirst().run()
    }

    @Test
    fun entryIsPendingWhileInFlightAndClearedAfter() {
        assertTrue(tracker.start("a", NUMBER))
        assertEquals(setOf("a"), tracker.pending)
        assertTrue(sent.isEmpty())

        drain()

        assertEquals(listOf(NUMBER), sent)
        assertTrue(tracker.pending.isEmpty())
        assertEquals(ReportOutcome.Sent, tracker.lastOutcome)
    }

    @Test
    fun secondStartForTheSameEntryIsIgnored() {
        assertTrue(tracker.start("a", NUMBER))
        assertFalse(tracker.start("a", NUMBER))
        drain()
        assertEquals(1, sent.size)
    }

    @Test
    fun resultIsKeptWithNoListenerAndShownToALaterOne() {
        answer = { ReportOutcome.NotSent() }
        val old = mutableListOf<ReportOutcome>()
        val oldListener: (ReportOutcome) -> Unit = { old += it }
        tracker.addListener(oldListener)
        tracker.start("a", NUMBER)

        // Rotation: the old screen stops before the result arrives.
        tracker.removeListener(oldListener)
        assertEquals(setOf("a"), tracker.pending)
        drain()

        assertTrue("a removed listener was called", old.isEmpty())
        assertEquals(ReportOutcome.NotSent(), tracker.lastOutcome)
        assertTrue(tracker.pending.isEmpty())
    }

    @Test
    fun attachedListenerGetsEveryResult() {
        val seen = mutableListOf<ReportOutcome>()
        tracker.addListener { seen += it }
        answer = { ReportOutcome.RateLimited }
        tracker.start("a", NUMBER)
        answer = { ReportOutcome.Refused }
        tracker.start("b", NUMBER)
        drain()
        assertEquals(listOf(ReportOutcome.RateLimited, ReportOutcome.Refused), seen)
    }

    @Test
    fun refusedDoesNotReplaceTheLastResult() {
        answer = { ReportOutcome.RateLimited }
        tracker.start("a", NUMBER)
        drain()
        answer = { ReportOutcome.Refused }
        tracker.start("b", NUMBER)
        drain()
        assertEquals(ReportOutcome.RateLimited, tracker.lastOutcome)
    }

    @Test
    fun sendExceptionIsNotSent() {
        answer = { throw IllegalStateException("boom") }
        tracker.start("a", NUMBER)
        drain()
        assertEquals(ReportOutcome.NotSent(), tracker.lastOutcome)
        assertTrue(tracker.pending.isEmpty())
    }

    @Test
    fun clearLastOutcomeForgetsTheResult() {
        tracker.start("a", NUMBER)
        drain()
        tracker.clearLastOutcome()
        assertNull(tracker.lastOutcome)
    }

    private companion object {
        // Test-only value; any E.164 string works, since send is faked.
        const val NUMBER = "+97255500999"
    }
}
