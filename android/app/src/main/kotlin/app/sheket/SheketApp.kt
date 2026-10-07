package app.sheket

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.sheket.data.AndroidBlocklistStore
import app.sheket.data.BlocklistRefresher
import app.sheket.data.BlocklistRepository
import app.sheket.data.BlocklistStore
import app.sheket.data.RefreshJobService
import app.sheket.screening.ScreenedCallLog
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The application object: the only place app singletons are created. There
 * is no DI framework; components reach the singletons through this class.
 *
 * [executor] is the single background thread of the app, shared by the
 * blocklist refresh, call screening and reporting.
 */
class SheketApp : Application() {

    val executor: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "sheket-bg") }

    val mainHandler: Handler = Handler(Looper.getMainLooper())

    val store: BlocklistStore by lazy { AndroidBlocklistStore(this) }

    val repository: BlocklistRepository by lazy {
        BlocklistRepository(store) { assets.open(SEED_ASSET).use { it.readBytes() } }
            .also {
                it.load()
                logLoaded(it)
            }
    }

    val refresher: BlocklistRefresher by lazy { BlocklistRefresher(repository, store) }

    val screenedCallLog: ScreenedCallLog by lazy { ScreenedCallLog(this) }

    override fun onCreate() {
        super.onCreate()
        // The repository is not loaded here: first use (on the executor or by
        // call screening) loads it, so the main thread does no list I/O.
        store.initFirstRunAt(System.currentTimeMillis())
        RefreshJobService.schedule(this)
    }

    // This log is how the manual AC-4 check (a fresh offline install loads the
    // seed) is verified. It lives here, not in the repository, so JVM tests
    // never touch android.util.Log.
    private fun logLoaded(repository: BlocklistRepository) {
        if (BuildConfig.DEBUG) Log.d(TAG, "blocklist loaded: ${repository.summary}")
    }

    private companion object {
        const val SEED_ASSET = "seed-blocklist.json"
        const val TAG = "Sheket"
    }
}
