package app.sheket.data

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import app.sheket.SheketApp
import java.util.concurrent.TimeUnit

/**
 * Periodic background refresh of the blocklist (spec 7).
 *
 * Runs [BlocklistRefresher.refresh] on the app's shared single-thread executor.
 *
 * Accepted limitations: Doze and app-standby buckets can delay the job, so the
 * refresh bound in [REFRESH_PERIOD_MS] is best effort. The job is not
 * persisted, so it is lost on reboot and scheduled again the next time the
 * process starts (`SheketApp.onCreate`).
 */
class RefreshJobService : JobService() {

    override fun onStartJob(params: JobParameters): Boolean {
        val app = applicationContext as SheketApp
        app.executor.execute {
            try {
                app.refresher.refresh()
            } finally {
                jobFinished(params, false)
            }
        }
        return true
    }

    // The refresh cannot be cancelled mid-flight; no reschedule is needed
    // because the next period runs anyway.
    override fun onStopJob(params: JobParameters): Boolean = false

    companion object {
        const val JOB_ID = 1

        /**
         * The refresh period: the JobScheduler minimum period of 15 minutes.
         *
         * The job is scheduled with the minimum flex ([JobInfo.getMinFlexMillis],
         * 5 minutes), so it runs somewhere in the last 5 minutes of each period
         * and two runs can be up to period + flex (about 20 minutes) apart. With
         * the 5 minute CDN cache, a `never_block` removal can take about 25
         * minutes to reach the client, and longer under Doze or app standby.
         * That is a known gap against spec 7 ("at most 15 minutes plus the 5
         * minute cache"): JobScheduler cannot run a periodic job more often.
         */
        val REFRESH_PERIOD_MS: Long = TimeUnit.MINUTES.toMillis(15)

        /** Schedules the periodic refresh unless it is already pending with the current period and flex. */
        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            // Checking the interval and flex, not just presence, means a change
            // to either (such as a job left by an older build with no flex)
            // takes effect after an app update.
            val pending = scheduler.getPendingJob(JOB_ID)
            if (pending?.intervalMillis == REFRESH_PERIOD_MS && pending.flexMillis == JobInfo.getMinFlexMillis()) return
            scheduler.schedule(
                JobInfo.Builder(JOB_ID, ComponentName(context, RefreshJobService::class.java))
                    .setPeriodic(REFRESH_PERIOD_MS, JobInfo.getMinFlexMillis())
                    // Runs only when a network is available; needs ACCESS_NETWORK_STATE in the manifest.
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    // Not persisted, so no RECEIVE_BOOT_COMPLETED permission is needed.
                    .setPersisted(false)
                    .build(),
            )
        }
    }
}
