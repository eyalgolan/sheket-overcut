package app.sheket.report

import app.sheket.BuildConfig
import app.sheket.core.SenderNormalizer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** Outcome of [ReportClient.send]. */
sealed interface ReportOutcome {
    /** The server answered 202; the number is marked reported. */
    data object Sent : ReportOutcome

    /** The server answered 429. Not retried. */
    data object RateLimited : ReportOutcome

    /**
     * The report was not sent: the endpoint failed twice, refused it, or the
     * request could not be made. [errorField] is the `error` field of a 400
     * response, if there was one, so the caller can log it.
     */
    data class NotSent(val errorField: String? = null) : ReportOutcome

    /** The number is not E.164 or was already reported; no request was made. */
    data object Refused : ReportOutcome
}

/**
 * Sends one `call` report (spec 6.2). On endpoint failure the report is retried
 * once, then dropped; nothing is queued on device (spec 7).
 *
 * The [url], [appVersion], timeout and retry-delay parameters exist only so
 * tests can target a local server; production uses the defaults.
 */
class ReportClient(
    private val installId: () -> String,
    private val isReported: (String) -> Boolean,
    private val markReported: (String) -> Unit,
    private val url: URL = URL(BuildConfig.REPORT_URL),
    private val appVersion: String = BuildConfig.VERSION_NAME,
    private val connectTimeoutMs: Int = CONNECT_TIMEOUT_MS,
    private val readTimeoutMs: Int = READ_TIMEOUT_MS,
    private val retryDelayMs: Long = RETRY_DELAY_MS,
) {

    /**
     * Reports [number] as an unwanted call, making at most two attempts.
     *
     * Blocking network I/O: call only on `SheketApp.executor`, never on the
     * main thread. Never throws. Nothing is queued: a report that is not sent
     * is dropped.
     */
    fun send(number: String): ReportOutcome = try {
        if (!SenderNormalizer.isE164(number) || isReported(number)) {
            ReportOutcome.Refused
        } else {
            val body = buildJsonObject {
                put("install_id", installId())
                put("platform", "android")
                put("kind", "call")
                put("sender", number)
                put("app_version", appVersion)
            }.toString().toByteArray(Charsets.UTF_8)

            val outcome = attempt(body) ?: run {
                Thread.sleep(retryDelayMs)
                attempt(body)
            } ?: ReportOutcome.NotSent()

            if (outcome == ReportOutcome.Sent) {
                try {
                    markReported(number)
                } catch (e: Exception) {
                    // The server accepted the report; a failed local mark only
                    // means the entry can be reported again.
                }
            }
            outcome
        }
    } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
        ReportOutcome.NotSent()
    } catch (e: Exception) {
        // installId(), isReported() or a non-I/O failure of the request.
        ReportOutcome.NotSent()
    }

    /** One POST of [body]; returns the outcome, or null if it may be retried. */
    private fun attempt(body: ByteArray): ReportOutcome? {
        var conn: HttpURLConnection? = null
        return try {
            val c = url.openConnection() as HttpURLConnection
            conn = c
            c.requestMethod = "POST"
            c.connectTimeout = connectTimeoutMs
            c.readTimeout = readTimeoutMs
            c.useCaches = false
            c.instanceFollowRedirects = false
            c.doOutput = true
            c.setFixedLengthStreamingMode(body.size)
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("Accept", "application/json")
            c.outputStream.use { it.write(body) }

            when (c.responseCode) {
                HttpURLConnection.HTTP_ACCEPTED -> ReportOutcome.Sent
                HTTP_TOO_MANY_REQUESTS -> ReportOutcome.RateLimited
                HttpURLConnection.HTTP_BAD_REQUEST -> ReportOutcome.NotSent(errorField(c))
                in 500..599 -> null
                else -> ReportOutcome.NotSent()
            }
        } catch (e: IOException) {
            // Timeouts, connection refused and the unresolvable .invalid
            // default host are all retryable.
            null
        } finally {
            conn?.disconnect()
        }
    }

    /** The top-level string `error` of a 400 body, or null. Never throws. */
    private fun errorField(conn: HttpURLConnection): String? = try {
        val bytes = conn.errorStream?.use(::readCapped)
        if (bytes == null) {
            null
        } else {
            val root = Json.parseToJsonElement(String(bytes, Charsets.UTF_8)) as? JsonObject
            (root?.get("error") as? JsonPrimitive)?.takeIf { it.isString }?.content
        }
    } catch (e: Exception) {
        null
    }

    /** Reads at most [MAX_ERROR_BYTES] bytes; a longer body is truncated. */
    private fun readCapped(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(MAX_ERROR_BYTES)
        while (out.size() < MAX_ERROR_BYTES) {
            val n = input.read(buffer, 0, MAX_ERROR_BYTES - out.size())
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 10_000
        const val READ_TIMEOUT_MS = 15_000
        const val RETRY_DELAY_MS = 2_000L

        /** Most bytes of a 400 body read for its `error` field. */
        private const val MAX_ERROR_BYTES = 1024
        private const val HTTP_TOO_MANY_REQUESTS = 429
    }
}
