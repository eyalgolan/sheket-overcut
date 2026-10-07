package app.sheket.report

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

/**
 * The random install ID sent with every report (spec 6.2): a canonical
 * lowercase UUID, created on first use and stored under `install_id` in the
 * `sheket` shared preferences.
 *
 * The prefs file is shared with `AndroidBlocklistStore`, whose keys are
 * `etag`, `last_success_at` and `first_run_at`. Backup exclusion comes from the
 * manifest (`allowBackup="false"`) and `res/xml/data_extraction_rules.xml`, so
 * a reinstall gets a new ID; the ID is not tied to a person (spec 6.2).
 */
class InstallId(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * The stored ID if it is canonical; otherwise a new random UUID, which is
     * stored (replacing any corrupt value) and returned. Blocking disk I/O:
     * call only on `SheketApp.executor`.
     */
    // commit(), not apply(): the ID is on disk before it is sent. This runs on
    // the background executor, never the main thread. If the commit fails the
    // new ID is still returned, and the next call creates another.
    @SuppressLint("ApplySharedPref")
    @Synchronized
    fun get(): String {
        val stored = try {
            prefs.getString(KEY_INSTALL_ID, null)
        } catch (e: ClassCastException) {
            // A non-string value under the key is corrupt; it is replaced below.
            null
        }
        if (stored != null && isCanonical(stored)) return stored
        val id = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_INSTALL_ID, id).commit()
        return id
    }

    companion object {
        private const val PREFS_NAME = "sheket"
        private const val KEY_INSTALL_ID = "install_id"

        // The form `_parse_install_id` in backend/src/sheket/report.py accepts,
        // restricted to lowercase. Applied with matches(), a full match.
        private val CANONICAL =
            Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        /** True only for a non-null, lowercase, hyphenated 36-character UUID. */
        fun isCanonical(s: String?): Boolean = s != null && CANONICAL.matches(s)
    }
}
