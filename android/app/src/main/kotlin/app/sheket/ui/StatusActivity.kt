package app.sheket.ui

import android.app.Activity
import android.app.role.RoleManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.TextView
import app.sheket.R
import app.sheket.SheketApp
import app.sheket.data.BlocklistSummary
import app.sheket.data.ListSource
import java.text.DateFormat
import java.time.OffsetDateTime
import java.util.Date
import java.util.Locale

/**
 * The status screen (#23): whether Sheket holds the call screening role, which
 * blocklist is in use and how old it is, and how many calls were blocked in
 * the last 7 days.
 *
 * When the role is off the screen says so and links to the switch (spec 7).
 * Each resume triggers one blocklist refresh on the app's single-thread
 * executor; the screen is drawn from what is on disk first and redrawn after
 * the refresh. No list, store or log I/O happens on the main thread.
 */
class StatusActivity : Activity() {

    private lateinit var app: SheketApp
    private var roleManager: RoleManager? = null

    private lateinit var roleStatus: TextView
    private lateinit var roleRequest: Button
    private lateinit var roleSettings: Button
    private lateinit var listGeneratedAt: TextView
    private lateinit var listCounts: TextView
    private lateinit var listSource: TextView
    private lateinit var staleLineView: TextView
    private lateinit var blockedCount: TextView

    /** True once a role request came back cancelled; shows the settings link. */
    private var requestCancelled = false

    /** Main thread only: a refresh is queued or running on the executor. */
    private var refreshInFlight = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_status)
        app = application as SheketApp
        roleManager = getSystemService(RoleManager::class.java)
        requestCancelled = savedInstanceState?.getBoolean(KEY_REQUEST_CANCELLED, false) ?: false

        roleStatus = findViewById(R.id.role_status)
        roleRequest = findViewById(R.id.role_request)
        roleSettings = findViewById(R.id.role_settings)
        listGeneratedAt = findViewById(R.id.list_generated_at)
        listCounts = findViewById(R.id.list_counts)
        listSource = findViewById(R.id.list_source)
        staleLineView = findViewById(R.id.stale_line)
        blockedCount = findViewById(R.id.blocked_count)

        roleRequest.setOnClickListener { requestRole() }
        roleSettings.setOnClickListener { openDefaultAppsSettings() }
        findViewById<Button>(R.id.about_button).setOnClickListener {
            startActivity(Intent(this, AboutActivity::class.java))
        }
    }

    override fun onResume() {
        super.onResume()
        renderRole()
        refreshAndRedraw()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_REQUEST_CANCELLED, requestCancelled)
    }

    private fun renderRole() {
        val rm = roleManager
        when {
            rm == null || !rm.isRoleAvailable(RoleManager.ROLE_CALL_SCREENING) -> {
                roleStatus.setText(R.string.role_unavailable)
                roleRequest.visibility = View.GONE
                roleSettings.visibility = View.GONE
            }
            rm.isRoleHeld(RoleManager.ROLE_CALL_SCREENING) -> {
                roleStatus.setText(R.string.role_on)
                roleRequest.visibility = View.GONE
                roleSettings.visibility = View.GONE
            }
            else -> {
                roleStatus.setText(R.string.role_off)
                roleRequest.visibility = View.VISIBLE
                roleSettings.visibility = if (requestCancelled) View.VISIBLE else View.GONE
            }
        }
    }

    private fun isRoleHeld(): Boolean =
        roleManager?.isRoleHeld(RoleManager.ROLE_CALL_SCREENING) == true

    // Framework result API on purpose: no AndroidX (decision 6).
    @Suppress("DEPRECATION")
    private fun requestRole() {
        val rm = roleManager ?: return
        try {
            startActivityForResult(rm.createRequestRoleIntent(RoleManager.ROLE_CALL_SCREENING), REQUEST_ROLE)
        } catch (e: ActivityNotFoundException) {
            requestCancelled = true
            renderRole()
        }
    }

    /**
     * After a past decline the system may return [RESULT_CANCELED] at once
     * without showing the dialog, so the settings link is shown after any
     * cancel; this is deliberate (spec 7, REQ-2).
     */
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_ROLE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        if (resultCode == RESULT_CANCELED && !isRoleHeld()) requestCancelled = true
        renderRole()
    }

    private fun openDefaultAppsSettings() {
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
        } catch (e: ActivityNotFoundException) {
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
            } catch (ignored: ActivityNotFoundException) {
                // No settings app; nothing more can be done.
            }
        }
    }

    /**
     * Draws from disk, refreshes the list, then redraws (AC-5). At most one
     * refresh per screen is queued; the flag is cleared exactly once, on the
     * main thread, and a failure never escapes onto the executor thread.
     */
    private fun refreshAndRedraw() {
        if (refreshInFlight) return
        refreshInFlight = true
        app.executor.execute {
            val result = runCatching {
                post(snapshot())
                app.refresher.refresh()
                snapshot()
            }.getOrNull()
            app.mainHandler.post {
                refreshInFlight = false
                if (result != null && isAlive()) render(result)
            }
        }
    }

    /** Executor only: reads each field independently so one failure degrades only that field. */
    private fun snapshot(): StatusSnapshot {
        val summary = runCatching { app.repository.summary }.getOrNull()
        val stale = runCatching {
            staleLine(System.currentTimeMillis(), app.store.lastSuccessAt(), app.store.firstRunAt())
        }.getOrDefault(StaleLine.Hidden)
        val count = runCatching { app.screenedCallLog.blockedInLast7Days() }.getOrDefault(0)
        return StatusSnapshot(summary, stale, count)
    }

    private fun post(s: StatusSnapshot) {
        app.mainHandler.post { if (isAlive()) render(s) }
    }

    private fun isAlive(): Boolean = !isDestroyed && !isFinishing

    private fun render(s: StatusSnapshot) {
        val summary = s.summary
        if (summary == null || summary.source == ListSource.NONE) {
            listGeneratedAt.text = getString(R.string.list_none)
            listCounts.visibility = View.GONE
            listSource.visibility = View.GONE
        } else {
            listGeneratedAt.text = getString(R.string.list_generated_at, formatGeneratedAt(summary.generatedAt))
            listCounts.text = getString(R.string.list_counts, summary.callNumbers, summary.callPrefixes)
            listCounts.visibility = View.VISIBLE
            listSource.setText(
                if (summary.source == ListSource.SEED) R.string.list_source_seed else R.string.list_source_downloaded,
            )
            listSource.visibility = View.VISIBLE
        }

        when (val stale = s.stale) {
            StaleLine.Hidden -> staleLineView.visibility = View.GONE
            is StaleLine.LastUpdated -> {
                val at = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(stale.atMillis))
                staleLineView.text = getString(R.string.stale_last_updated, at)
                staleLineView.visibility = View.VISIBLE
            }
            StaleLine.NeverUpdated -> {
                staleLineView.setText(R.string.stale_never_updated)
                staleLineView.visibility = View.VISIBLE
            }
        }

        blockedCount.text = getString(R.string.blocked_last_7_days, s.blockedCount)
    }

    /** The list's `generated_at` as a local medium date; the raw string if it does not parse. */
    private fun formatGeneratedAt(generatedAt: String?): String {
        if (generatedAt == null) return ""
        return runCatching {
            val odt = OffsetDateTime.parse(generatedAt.uppercase(Locale.ROOT))
            DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date.from(odt.toInstant()))
        }.getOrDefault(generatedAt)
    }

    private data class StatusSnapshot(
        val summary: BlocklistSummary?,
        val stale: StaleLine,
        val blockedCount: Int,
    )

    private companion object {
        const val REQUEST_ROLE = 1
        const val KEY_REQUEST_CANCELLED = "request_cancelled"
    }
}
