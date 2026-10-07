package app.sheket.data

import java.io.IOException

/**
 * In-memory [BlocklistStore] for JVM tests. Android's `AtomicFile` and
 * `SharedPreferences` are not available on the JVM, so tests use this fake
 * behind the same seam the app uses.
 */
class FakeBlocklistStore(var list: ByteArray? = null, var storedEtag: String? = null) : BlocklistStore {

    /** When set, [writeList] throws this and changes nothing but the ETag, as the real store does. */
    var writeFailure: IOException? = null

    /** When set, [readList] throws this, violating its contract, to prove callers still never throw. */
    var readFailure: RuntimeException? = null

    var writes = 0
        private set

    var lastSuccess: Long? = null
    var firstRun: Long? = null

    override fun readList(): ByteArray? {
        readFailure?.let { throw it }
        return list
    }

    override fun writeList(bytes: ByteArray, etag: String?) {
        // The real store clears the ETag before writing the file.
        storedEtag = null
        writeFailure?.let { throw it }
        list = bytes.copyOf()
        storedEtag = etag
        writes++
    }

    override fun etag(): String? = storedEtag

    override fun clearEtag() {
        storedEtag = null
    }

    override fun recordSuccess(atMillis: Long) {
        lastSuccess = atMillis
    }

    override fun lastSuccessAt(): Long? = lastSuccess

    override fun initFirstRunAt(atMillis: Long) {
        if (firstRun == null) firstRun = atMillis
    }

    override fun firstRunAt(): Long? = firstRun
}
