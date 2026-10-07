package app.sheket.ui

import android.app.Activity
import android.os.Bundle
import android.text.BidiFormatter
import android.text.TextDirectionHeuristics
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.Button
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.TextView
import app.sheket.R
import app.sheket.SheketApp
import app.sheket.report.ReportOutcome
import app.sheket.screening.ScreenedCall
import java.text.DateFormat
import java.util.Date

/**
 * The report screen (#24, spec section 5): the screened-call log, newest
 * first, with a one-tap Report button on each entry whose number is E.164 and
 * not yet reported (spec 6.2).
 *
 * The log is read on the app's single-thread executor. Reports are sent
 * through the app-scoped [app.sheket.report.ReportTracker], so the UI never
 * waits on the result (spec 6.2), and a report in flight across a rotation
 * keeps its spinner and its result. A report that is not sent is dropped and
 * the user is told so (spec 7). After every report the log is reread, so all
 * entries with the reported number show as reported.
 */
class ReportActivity : Activity() {

    private lateinit var app: SheketApp
    private lateinit var list: ListView
    private lateinit var empty: TextView
    private lateinit var result: TextView
    private val adapter = CallAdapter()
    private val dateFormat: DateFormat = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)

    /** Main thread only: the log as last read, newest first. */
    private var entries: List<ScreenedCall> = emptyList()

    /** Attached to the tracker while started; holds this instance only then. */
    private val onOutcome: (ReportOutcome) -> Unit = { outcome ->
        showResult(outcome)
        reload()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_report)
        app = application as SheketApp
        list = findViewById(R.id.report_list)
        empty = findViewById(R.id.report_empty)
        result = findViewById(R.id.report_result)
        list.adapter = adapter
    }

    override fun onStart() {
        super.onStart()
        app.reportTracker.addListener(onOutcome)
    }

    override fun onResume() {
        super.onResume()
        // A result that arrived while no instance was started, or before a
        // rotation, is shown again; showing it twice sets the same text.
        app.reportTracker.lastOutcome?.let(::showResult)
        reload()
    }

    override fun onStop() {
        app.reportTracker.removeListener(onOutcome)
        super.onStop()
    }

    override fun onDestroy() {
        // Leaving the screen, not a rotation: the next visit starts without
        // the old result. A report still in flight sets a new one.
        if (isFinishing) app.reportTracker.clearLastOutcome()
        super.onDestroy()
    }

    /** Reads the log on the executor and redraws the list. */
    private fun reload() {
        app.executor.execute {
            val read = runCatching { app.screenedCallLog.entries() }.getOrDefault(emptyList())
            app.mainHandler.post {
                if (isAlive()) {
                    entries = read
                    adapter.notifyDataSetChanged()
                    // Set only after the first read, so the empty text does not
                    // flash before the log has loaded.
                    if (list.emptyView == null) list.emptyView = empty
                }
            }
        }
    }

    /** Sends one report for [entry], whose number is E.164 (only such rows have a button). */
    private fun report(entry: ScreenedCall) {
        val number = entry.number ?: return
        if (app.reportTracker.start(entry.id, number)) adapter.notifyDataSetChanged()
    }

    private fun showResult(outcome: ReportOutcome) {
        val message = when (outcome) {
            ReportOutcome.Sent -> R.string.report_result_sent
            ReportOutcome.RateLimited -> R.string.report_result_try_later
            is ReportOutcome.NotSent -> R.string.report_result_not_sent
            // Already reported or not E.164: no request was made, so the
            // previous message is left as is; the reload shows the state.
            ReportOutcome.Refused -> return
        }
        result.setText(message)
        result.visibility = View.VISIBLE
    }

    private fun isAlive(): Boolean = !isDestroyed && !isFinishing

    private class RowViews(
        val number: TextView,
        val detail: TextView,
        val report: Button,
        val progress: ProgressBar,
        val state: TextView,
    )

    private inner class CallAdapter : BaseAdapter() {

        override fun getCount(): Int = entries.size

        override fun getItem(position: Int): ScreenedCall = entries[position]

        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val view = convertView ?: layoutInflater.inflate(R.layout.item_screened_call, parent, false).also {
                it.tag = RowViews(
                    number = it.findViewById(R.id.call_number),
                    detail = it.findViewById(R.id.call_detail),
                    report = it.findViewById(R.id.call_report),
                    progress = it.findViewById(R.id.call_progress),
                    state = it.findViewById(R.id.call_state),
                )
            }
            bind(view.tag as RowViews, getItem(position))
            return view
        }

        /** Sets every view of the row, since rows are reused. */
        private fun bind(row: RowViews, entry: ScreenedCall) {
            val number = entry.number
            row.number.text = if (number == null) {
                getString(R.string.report_number_unknown)
            } else {
                // Numbers read left to right even in a Hebrew layout.
                BidiFormatter.getInstance().unicodeWrap(number, TextDirectionHeuristics.LTR)
            }
            // The time and the outcome; the time keeps its own direction in a Hebrew layout.
            val time = BidiFormatter.getInstance().unicodeWrap(dateFormat.format(Date(entry.at)))
            row.detail.text = getString(
                if (entry.blocked) R.string.report_row_blocked else R.string.report_row_rang,
                time,
            )

            row.report.setOnClickListener(null)
            when {
                entry.id in app.reportTracker.pending -> {
                    row.report.visibility = View.GONE
                    row.progress.visibility = View.VISIBLE
                    row.state.visibility = View.GONE
                }
                entry.reported -> showState(row, R.string.report_state_reported)
                !entry.reportable -> showState(row, R.string.report_state_not_reportable)
                else -> {
                    row.report.visibility = View.VISIBLE
                    row.report.isEnabled = true
                    row.report.setOnClickListener { report(entry) }
                    row.progress.visibility = View.GONE
                    row.state.visibility = View.GONE
                }
            }
        }

        private fun showState(row: RowViews, text: Int) {
            row.report.visibility = View.GONE
            row.progress.visibility = View.GONE
            row.state.setText(text)
            row.state.visibility = View.VISIBLE
        }
    }
}
