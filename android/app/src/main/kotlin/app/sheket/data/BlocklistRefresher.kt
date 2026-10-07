package app.sheket.data

import app.sheket.BuildConfig
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** Outcome of [BlocklistRefresher.refresh]. */
enum class RefreshOutcome {
    /** The server answered 304; the stored list is current. */
    NOT_MODIFIED,

    /** A newer list was downloaded, stored and made current. */
    UPDATED,

    /** A valid list was downloaded but its `version` is not newer; the current list is kept. */
    NOT_NEWER,

    /** The downloaded document was invalid or too large and was rejected whole. */
    REJECTED,

    /** The request failed, the status was unexpected, or the list could not be stored. */
    FAILED,
}

/**
 * Downloads the blocklist (spec 6.1) and hands it to [repository].
 *
 * Only a 304 or a valid document records `last_success_at`; on any failure the
 * current list is kept (spec 7).
 *
 * The [url], timeout and [now] parameters exist only so tests can target a
 * local server; production uses the defaults.
 */
class BlocklistRefresher(
    private val repository: BlocklistRepository,
    private val store: BlocklistStore,
    private val url: URL = URL(BuildConfig.BLOCKLIST_URL),
    private val connectTimeoutMs: Int = CONNECT_TIMEOUT_MS,
    private val readTimeoutMs: Int = READ_TIMEOUT_MS,
    private val now: () -> Long = System::currentTimeMillis,
) {

    /**
     * Performs one conditional GET of the blocklist. Calls are serialised.
     *
     * Blocking network I/O: never call on the main thread. In the app it runs
     * only on the shared single-thread executor. Never throws.
     */
    @Synchronized
    fun refresh(): RefreshOutcome {
        var conn: HttpURLConnection? = null
        return try {
            val c = url.openConnection() as HttpURLConnection
            conn = c
            c.requestMethod = "GET"
            c.connectTimeout = connectTimeoutMs
            c.readTimeout = readTimeoutMs
            c.useCaches = false
            c.setRequestProperty("Accept", "application/json")
            store.etag()?.let { c.setRequestProperty("If-None-Match", it) }

            when (c.responseCode) {
                HttpURLConnection.HTTP_NOT_MODIFIED -> {
                    store.recordSuccess(now())
                    RefreshOutcome.NOT_MODIFIED
                }
                HttpURLConnection.HTTP_OK -> handleOk(c)
                else -> RefreshOutcome.FAILED
            }
        } catch (e: Exception) {
            // IOException (including timeouts and the unresolvable .invalid
            // default host), SecurityException, ClassCastException and the
            // like: keep the current list and record nothing.
            RefreshOutcome.FAILED
        } finally {
            conn?.disconnect()
        }
    }

    private fun handleOk(conn: HttpURLConnection): RefreshOutcome {
        if (conn.contentLengthLong > MAX_BODY_BYTES) return RefreshOutcome.REJECTED
        // HttpURLConnection decodes gzip transparently, so the cap applies to
        // the decoded bytes, which is the safe direction.
        val bytes = conn.inputStream.use(::readBounded) ?: return RefreshOutcome.REJECTED
        // A rejected document never touches the ETag or last_success_at: only
        // accept writes the ETag, together with the document it describes.
        return when (repository.accept(bytes, conn.getHeaderField("ETag"))) {
            AcceptResult.ACCEPTED -> {
                store.recordSuccess(now())
                RefreshOutcome.UPDATED
            }
            AcceptResult.NOT_NEWER -> {
                store.recordSuccess(now())
                RefreshOutcome.NOT_NEWER
            }
            AcceptResult.REJECTED -> RefreshOutcome.REJECTED
            AcceptResult.STORE_FAILED -> RefreshOutcome.FAILED
        }
    }

    /**
     * Reads at most [MAX_BODY_BYTES] + 1 bytes; returns null if the body is
     * larger than [MAX_BODY_BYTES]. Covers bodies with no Content-Length.
     */
    private fun readBounded(input: InputStream): ByteArray? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (total <= MAX_BODY_BYTES) {
            val n = input.read(buffer, 0, minOf(buffer.size, MAX_BODY_BYTES + 1 - total))
            if (n < 0) return out.toByteArray()
            out.write(buffer, 0, n)
            total += n
        }
        return null
    }

    companion object {
        /** Largest accepted body, in decoded bytes. */
        const val MAX_BODY_BYTES = 5 * 1024 * 1024
        const val CONNECT_TIMEOUT_MS = 10_000
        const val READ_TIMEOUT_MS = 15_000
    }
}
