package app.sheket.data

import android.content.Context
import android.content.SharedPreferences
import android.util.AtomicFile
import java.io.File
import java.io.IOException

/**
 * Local storage for the blocklist document and its refresh metadata.
 *
 * The list's `version` and `generated_at` are never stored here; they are
 * always read from the parsed document, so they cannot drift from it.
 */
interface BlocklistStore {

    /** The raw stored document, or null if it is missing or unreadable. Never throws. */
    fun readList(): ByteArray?

    /**
     * Replaces the stored document and its ETag together; a null [etag] leaves
     * no ETag stored.
     *
     * @throws IOException if the document could not be written.
     */
    fun writeList(bytes: ByteArray, etag: String?)

    /** The ETag of the stored document, or null if none is stored. */
    fun etag(): String?

    /** Forgets the stored ETag, so the next request fetches the full document. */
    fun clearEtag()

    /** Records [atMillis] (epoch milliseconds) as `last_success_at`. */
    fun recordSuccess(atMillis: Long)

    /** `last_success_at` in epoch milliseconds, or null if never recorded. */
    fun lastSuccessAt(): Long?

    /** Sets `first_run_at` to [atMillis] (epoch milliseconds) only if it is absent. */
    fun initFirstRunAt(atMillis: Long)

    /** `first_run_at` in epoch milliseconds, or null if never set. */
    fun firstRunAt(): Long?
}

/**
 * [BlocklistStore] backed by `blocklist.json` in the app's files directory,
 * written through [AtomicFile], and the `sheket` shared preferences.
 */
class AndroidBlocklistStore(context: Context) : BlocklistStore {

    private val atomicFile = AtomicFile(File(context.filesDir, LIST_FILE))
    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun readList(): ByteArray? =
        try {
            atomicFile.readFully()
        } catch (e: IOException) {
            // Includes FileNotFoundException: no list stored yet.
            null
        }

    override fun writeList(bytes: ByteArray, etag: String?) {
        // Order matters: a stored ETag must never describe a file other than
        // the stored one. If the process dies after the file is written but
        // before the new ETag is, the new file is stored with no ETag; the next
        // request gets a full 200 that is not newer, which is safe and costs
        // only bandwidth.
        //
        // AtomicFile.finishWrite logs rather than throws when fsync or the
        // rename fails, so the file is read back before the ETag is stored.
        // Without that check the new ETag could sit next to the old file and
        // the client could be stuck behind a 304. Throwing there is safe: the
        // ETag was already cleared, so the old file is left with no ETag.
        if (!prefs.edit().remove(KEY_ETAG).commit()) {
            throw IOException("could not clear the stored ETag")
        }
        val out = atomicFile.startWrite()
        try {
            out.write(bytes)
        } catch (e: Throwable) {
            atomicFile.failWrite(out)
            throw e
        }
        atomicFile.finishWrite(out)
        if (!atomicFile.readFully().contentEquals(bytes)) {
            throw IOException("stored list does not match the written bytes")
        }
        if (etag != null) {
            // A false commit leaves no ETag stored, which is safe.
            prefs.edit().putString(KEY_ETAG, etag).commit()
        }
    }

    override fun etag(): String? = prefs.getString(KEY_ETAG, null)

    override fun clearEtag() {
        prefs.edit().remove(KEY_ETAG).commit()
    }

    override fun recordSuccess(atMillis: Long) {
        prefs.edit().putLong(KEY_LAST_SUCCESS_AT, atMillis).apply()
    }

    override fun lastSuccessAt(): Long? = readLong(KEY_LAST_SUCCESS_AT)

    override fun initFirstRunAt(atMillis: Long) {
        if (!prefs.contains(KEY_FIRST_RUN_AT)) {
            prefs.edit().putLong(KEY_FIRST_RUN_AT, atMillis).apply()
        }
    }

    override fun firstRunAt(): Long? = readLong(KEY_FIRST_RUN_AT)

    private fun readLong(key: String): Long? =
        if (prefs.contains(key)) prefs.getLong(key, 0L) else null

    private companion object {
        const val LIST_FILE = "blocklist.json"
        const val PREFS_NAME = "sheket"
        const val KEY_ETAG = "etag"
        const val KEY_LAST_SUCCESS_AT = "last_success_at"
        const val KEY_FIRST_RUN_AT = "first_run_at"
    }
}
