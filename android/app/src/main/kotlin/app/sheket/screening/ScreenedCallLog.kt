package app.sheket.screening

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * The local screened-call log (#22), stored as `screened-calls.json` in the
 * app's files directory and written through [AtomicFile]. The encoding is
 * [ScreenedCallCodec]'s; entries are kept newest first.
 *
 * Every public method does blocking file I/O and must be called only on
 * `SheketApp.executor`, never on the main thread. The executor gives the
 * ordering; the lock only guards against misuse from another thread.
 *
 * The file is app-private and excluded from backup by the manifest and
 * `data_extraction_rules` (spec 6.2); it never leaves the device.
 */
class ScreenedCallLog(context: Context) {

    private val atomicFile = AtomicFile(File(context.filesDir, LOG_FILE))

    /** The stored entries, newest first; empty if the file is missing or unreadable. */
    @Synchronized
    fun entries(): List<ScreenedCall> = ScreenedCallCodec.decode(readOrNull())

    /**
     * Adds a new, unreported entry as the newest; the oldest beyond
     * [ScreenedCallCodec.MAX_ENTRIES] is dropped.
     *
     * @throws IOException if the log could not be written.
     */
    @Synchronized
    fun append(number: String?, atMillis: Long, blocked: Boolean) {
        val entry = ScreenedCall(
            id = UUID.randomUUID().toString(),
            number = number,
            at = atMillis,
            blocked = blocked,
            reported = false,
        )
        write(ScreenedCallCodec.prepend(entries(), entry))
    }

    /**
     * Marks every entry whose number is [number] as reported. Writes only if
     * something changed.
     *
     * @throws IOException if the log could not be written.
     */
    @Synchronized
    fun markReported(number: String) {
        val current = entries()
        val updated = ScreenedCallCodec.markReported(current, number)
        if (updated != current) write(updated)
    }

    /** How many entries were blocked in the 7 days up to [nowMillis]. */
    @Synchronized
    fun blockedInLast7Days(nowMillis: Long = System.currentTimeMillis()): Int =
        ScreenedCallCodec.countBlockedSince(entries(), nowMillis - SEVEN_DAYS_MS)

    private fun readOrNull(): ByteArray? = try {
        atomicFile.readFully()
    } catch (e: IOException) {
        // Includes FileNotFoundException: nothing logged yet.
        null
    }

    private fun write(entries: List<ScreenedCall>) {
        val out = atomicFile.startWrite()
        try {
            out.write(ScreenedCallCodec.encode(entries))
        } catch (e: Throwable) {
            atomicFile.failWrite(out)
            throw e
        }
        atomicFile.finishWrite(out)
    }

    private companion object {
        const val LOG_FILE = "screened-calls.json"
        val SEVEN_DAYS_MS = TimeUnit.DAYS.toMillis(7)
    }
}
