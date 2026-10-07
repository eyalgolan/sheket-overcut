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
 * Accepted limitations: Doze and app-standby buckets can delay the job. The job
 * is not persisted, so it is lost on reboot and scheduled again the next time
 * the process starts (`SheketApp.onCreate`).
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
         * The refresh period: the JobScheduler minimum period (spec 7). A
         * `never_block` removal reaches the client within one period.
         */
        val REFRESH_PERIOD_MS: Long = TimeUnit.MINUTES.toMillis(15)

        /** Schedules the periodic refresh unless it is already pending with the current period. */
        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            // Checking the interval, not just presence, means a future change
            // to REFRESH_PERIOD_MS takes effect after an app update.
            if (scheduler.getPendingJob(JOB_ID)?.intervalMillis == REFRESH_PERIOD_MS) return
            scheduler.schedule(
                JobInfo.Builder(JOB_ID, ComponentName(context, RefreshJobService::class.java))
                    .setPeriodic(REFRESH_PERIOD_MS)
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    // Not persisted, so no RECEIVE_BOOT_COMPLETED permission is needed.
                    .setPersisted(false)
                    .build(),
            )
        }
    }
}
