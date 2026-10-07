package app.sheket.screening

import android.telecom.Call
import android.telecom.CallScreeningService
import android.util.Log
import app.sheket.BuildConfig
import app.sheket.SheketApp

/**
 * Screens incoming calls (#22, spec 4): a caller on the blocklist is rejected
 * before the phone rings.
 *
 * - `READ_CONTACTS` is not held, so Android asks this service only about
 *   callers not in the user's contacts; contacts are never looked up here.
 * - Telecom allows about 5 seconds for an answer, so the decision uses only the
 *   local list and does no network I/O.
 * - Any failure while deciding allows the call.
 * - The screened-call log is written on `SheketApp.executor` only after the
 *   response has been sent, so logging can never delay or break screening.
 */
class SheketScreeningService : CallScreeningService() {

    override fun onScreenCall(details: Call.Details) {
        val now = System.currentTimeMillis()

        var app: SheketApp? = null
        val decision: ScreeningDecision? = try {
            val sheketApp = applicationContext as SheketApp
            app = sheketApp
            val incoming = details.callDirection == Call.Details.DIRECTION_INCOMING
            if (!incoming) {
                null
            } else {
                ScreeningDecider.decide(details.handle?.scheme, details.handle?.schemeSpecificPart) {
                    sheketApp.repository.matcher
                }
            }
        } catch (e: Throwable) {
            if (BuildConfig.DEBUG) Log.d(TAG, "screening failed; allowing call: ${e.javaClass.simpleName}")
            null
        }

        val response = if (decision?.block == true) {
            CallResponse.Builder()
                .setDisallowCall(true)
                .setRejectCall(true)
                .setSkipCallLog(false)
                .setSkipNotification(true)
                .build()
        } else {
            CallResponse.Builder().build()
        }
        respondToCall(details, response)

        val loggingApp = app
        if (decision != null && loggingApp != null) {
            logScreenedCall(loggingApp, decision, now)
        }
    }

    private fun logScreenedCall(app: SheketApp, decision: ScreeningDecision, atMillis: Long) {
        try {
            app.executor.execute {
                try {
                    app.screenedCallLog.append(decision.number, atMillis, decision.block)
                } catch (e: Exception) {
                    if (BuildConfig.DEBUG) Log.d(TAG, "screened-call log write failed: ${e.javaClass.simpleName}")
                }
            }
        } catch (e: Throwable) {
            if (BuildConfig.DEBUG) Log.d(TAG, "screened-call log not submitted: ${e.javaClass.simpleName}")
        }
    }

    private companion object {
        const val TAG = "Sheket"
    }
}
