package app.sheket.ui

import app.sheket.data.FakeBlocklistStore
import org.junit.Assert.assertEquals
import org.junit.Test

/** The stale "last updated" rule (AC-2, spec 7, provisional OQ-3 answer). */
class StaleLineTest {

    private val hour = 60L * 60 * 1000
    private val t0 = 1_791_000_000_000L // An arbitrary fixed epoch time; no clock is read.

    @Test
    fun staleAfterIs24Hours() {
        assertEquals(86_400_000L, STALE_AFTER_MS)
    }

    @Test
    fun hiddenWhenNothingIsKnown() {
        assertEquals(StaleLine.Hidden, staleLine(t0, lastSuccessAt = null, firstRunAt = null))
    }

    // AC-2: hidden before 24 hours from first_run_at when no check has succeeded.

    @Test
    fun hiddenBefore24HoursFromFirstRunWithoutSuccess() {
        assertEquals(StaleLine.Hidden, staleLine(t0, null, firstRunAt = t0))
        assertEquals(StaleLine.Hidden, staleLine(t0 + 1, null, firstRunAt = t0))
        assertEquals(StaleLine.Hidden, staleLine(t0 + 23 * hour, null, firstRunAt = t0))
    }

    @Test
    fun hiddenAtExactly24HoursFromFirstRun() {
        assertEquals(StaleLine.Hidden, staleLine(t0 + STALE_AFTER_MS, null, firstRunAt = t0))
    }

    @Test
    fun neverUpdatedJustOver24HoursFromFirstRunWithoutSuccess() {
        assertEquals(StaleLine.NeverUpdated, staleLine(t0 + STALE_AFTER_MS + 1, null, firstRunAt = t0))
        assertEquals(StaleLine.NeverUpdated, staleLine(t0 + 30 * 24 * hour, null, firstRunAt = t0))
    }

    // AC-2: shown after 24 hours from last_success_at.

    @Test
    fun shownAfter24HoursFromLastSuccess() {
        val last = t0 + 2 * hour
        assertEquals(StaleLine.LastUpdated(last), staleLine(last + 25 * hour, lastSuccessAt = last, firstRunAt = t0))
    }

    @Test
    fun lastSuccessBoundaryIsStrictlyMoreThan24Hours() {
        assertEquals(StaleLine.Hidden, staleLine(t0 + STALE_AFTER_MS, lastSuccessAt = t0, firstRunAt = t0))
        assertEquals(StaleLine.LastUpdated(t0), staleLine(t0 + STALE_AFTER_MS + 1, lastSuccessAt = t0, firstRunAt = t0))
    }

    @Test
    fun lastSuccessWithoutFirstRunStillCounts() {
        assertEquals(StaleLine.LastUpdated(t0), staleLine(t0 + 48 * hour, lastSuccessAt = t0, firstRunAt = null))
        assertEquals(StaleLine.Hidden, staleLine(t0 + hour, lastSuccessAt = t0, firstRunAt = null))
    }

    // AC-2: hidden right after a 304.

    @Test
    fun hiddenRightAfterA304EvenWhenFirstRunIsOld() {
        val store = FakeBlocklistStore()
        store.initFirstRunAt(t0)
        val now = t0 + 10 * 24 * hour
        assertEquals(StaleLine.NeverUpdated, staleLine(now, store.lastSuccessAt(), store.firstRunAt()))

        // The refresher records success on a 304 exactly as on a valid 200.
        store.recordSuccess(now)
        assertEquals(StaleLine.Hidden, staleLine(now, store.lastSuccessAt(), store.firstRunAt()))
    }

    @Test
    fun hiddenRightAfterA304ThatFollowsAStaleSuccess() {
        val oldSuccess = t0
        val now = t0 + 3 * 24 * hour
        assertEquals(StaleLine.LastUpdated(oldSuccess), staleLine(now, oldSuccess, t0))
        assertEquals(StaleLine.Hidden, staleLine(now, lastSuccessAt = now, firstRunAt = t0))
    }

    @Test
    fun lastSuccessTakesPrecedenceOverFirstRun() {
        // first_run_at is old but a recent success makes the list fresh.
        assertEquals(StaleLine.Hidden, staleLine(t0 + 100 * hour, lastSuccessAt = t0 + 99 * hour, firstRunAt = t0))
        // A stale success is measured from itself, even if first_run_at is newer (e.g. reset prefs).
        assertEquals(
            StaleLine.LastUpdated(t0),
            staleLine(t0 + 30 * hour, lastSuccessAt = t0, firstRunAt = t0 + 29 * hour),
        )
    }

    @Test
    fun hiddenWhenBaselineIsInTheFuture() {
        // The clock was moved back after the last success or the first run.
        assertEquals(StaleLine.Hidden, staleLine(t0, lastSuccessAt = t0 + 5 * 24 * hour, firstRunAt = null))
        assertEquals(StaleLine.Hidden, staleLine(t0, lastSuccessAt = null, firstRunAt = t0 + 5 * 24 * hour))
    }
}
