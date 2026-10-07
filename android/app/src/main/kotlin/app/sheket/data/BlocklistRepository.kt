package app.sheket.data

import app.sheket.core.Blocklist
import app.sheket.core.BlocklistParser
import app.sheket.core.CallMatcher
import app.sheket.core.ParseResult
import java.io.IOException

/** Where the list in memory came from. */
enum class ListSource { STORED, SEED, NONE }

/**
 * What the status screen shows about the list in memory. [version] and
 * [generatedAt] are null when [source] is [ListSource.NONE].
 */
data class BlocklistSummary(
    val version: Long?,
    val generatedAt: String?,
    val callNumbers: Int,
    val callPrefixes: Int,
    val source: ListSource,
)

/** Outcome of [BlocklistRepository.accept]. */
enum class AcceptResult {
    /** The document was stored and is now the list in memory. */
    ACCEPTED,

    /** The document is valid but its `version` is not greater than the current one. */
    NOT_NEWER,

    /** The document failed schema 1 validation and was rejected whole. */
    REJECTED,

    /** The document is newer but could not be stored; the current list is kept. */
    STORE_FAILED,
}

/**
 * Holds the blocklist in memory and keeps it consistent with [store].
 *
 * - Version gate (spec 6.1): a list replaces the current one only if its
 *   `version` is strictly greater.
 * - Whole-document rejection (spec 7): a document that fails validation is
 *   ignored entirely and the previous list is kept.
 * - ETag rule: an ETag is stored only together with an accepted document, and
 *   is cleared whenever the list in memory is not the stored file (seed or no
 *   list). Otherwise a 304 could keep the client behind a list it never loaded.
 *
 * [matcher] and [summary] are swapped together in a single reference write,
 * so a reader (the call screening service, spec 4) never takes a lock and
 * never sees a matcher from one list with the summary of another.
 *
 * @param seed reads the bundled seed list; null or a throw means no seed.
 */
class BlocklistRepository(private val store: BlocklistStore, private val seed: () -> ByteArray?) {

    private class State(val blocklist: Blocklist?, val matcher: CallMatcher, val summary: BlocklistSummary)

    @Volatile
    private var state: State = EMPTY

    /** Matcher for the list in memory; matches nothing until a list is loaded. */
    val matcher: CallMatcher get() = state.matcher

    /** Summary of the list in memory. */
    val summary: BlocklistSummary get() = state.summary

    /**
     * Loads the stored list, or the bundled seed if it is newer or the stored
     * list is missing or invalid; on a version tie the stored list wins, so its
     * ETag stays valid. Never throws.
     */
    @Synchronized
    fun load() {
        try {
            val stored = store.readList()?.let(::parseOk)
            val seeded = try {
                seed()
            } catch (e: Exception) {
                null
            }?.let(::parseOk)
            state = when {
                stored != null && (seeded == null || stored.version >= seeded.version) ->
                    stateOf(stored, ListSource.STORED)
                seeded != null -> {
                    store.clearEtag()
                    stateOf(seeded, ListSource.SEED)
                }
                else -> {
                    store.clearEtag()
                    EMPTY
                }
            }
        } catch (e: Exception) {
            state = EMPTY
            try {
                store.clearEtag()
            } catch (ignored: Exception) {
                // Best effort; nothing more can be done here.
            }
        }
    }

    /**
     * Validates a downloaded document with its [etag] and, if it is newer than
     * the list in memory, stores it and makes it current.
     */
    @Synchronized
    fun accept(bytes: ByteArray, etag: String?): AcceptResult {
        val blocklist = parseOk(bytes) ?: return AcceptResult.REJECTED
        val current = state.blocklist
        if (current != null && blocklist.version <= current.version) return AcceptResult.NOT_NEWER
        try {
            store.writeList(bytes, etag)
        } catch (e: IOException) {
            // writeList clears the ETag first, so the old file and ETag still
            // agree; the next refresh retries.
            return AcceptResult.STORE_FAILED
        }
        state = stateOf(blocklist, ListSource.STORED)
        return AcceptResult.ACCEPTED
    }

    private fun parseOk(bytes: ByteArray): Blocklist? = (BlocklistParser.parse(bytes) as? ParseResult.Ok)?.blocklist

    private fun stateOf(blocklist: Blocklist, source: ListSource) = State(
        blocklist = blocklist,
        matcher = CallMatcher(blocklist),
        summary = BlocklistSummary(
            version = blocklist.version,
            generatedAt = blocklist.generatedAt,
            callNumbers = blocklist.callNumbers.size,
            callPrefixes = blocklist.callPrefixes.size,
            source = source,
        ),
    )

    private companion object {
        val EMPTY = State(
            blocklist = null,
            matcher = CallMatcher(Blocklist(0, "", emptySet(), emptySet())),
            summary = BlocklistSummary(null, null, 0, 0, ListSource.NONE),
        )
    }
}
