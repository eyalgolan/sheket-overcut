package app.sheket.data

import app.sheket.data.TestDocuments.NEWER_VERSION
import app.sheket.data.TestDocuments.SEED_GENERATED_AT
import app.sheket.data.TestDocuments.SEED_VERSION
import app.sheket.data.TestDocuments.TEST_CALL_NUMBERS
import app.sheket.data.TestDocuments.TEST_CALL_PREFIXES
import app.sheket.data.TestDocuments.TEST_GENERATED_AT
import app.sheket.data.TestDocuments.TEST_LIST_NUMBER
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class BlocklistRepositoryTest {

    private fun repository(store: FakeBlocklistStore, seed: () -> ByteArray? = { TestDocuments.seed }) =
        BlocklistRepository(store, seed)

    private fun assertNone(repository: BlocklistRepository) {
        assertEquals(BlocklistSummary(null, null, 0, 0, ListSource.NONE), repository.summary)
        assertFalse(repository.matcher.shouldBlock(TEST_LIST_NUMBER))
    }

    // --- Before load and load() ---

    @Test
    fun beforeLoadTheMatcherIsEmpty() {
        assertNone(repository(FakeBlocklistStore()))
    }

    @Test
    fun freshInstallLoadsTheSeedAndClearsTheEtag() {
        val store = FakeBlocklistStore(storedEtag = "\"stale\"")
        val repo = repository(store)

        repo.load()

        assertEquals(ListSource.SEED, repo.summary.source)
        assertEquals(SEED_VERSION, repo.summary.version)
        assertEquals(SEED_GENERATED_AT, repo.summary.generatedAt)
        assertNull(store.storedEtag)
        assertEquals(0, store.writes)
    }

    @Test
    fun newerStoredListWinsOverTheSeedAndKeepsItsEtag() {
        val store = FakeBlocklistStore(list = TestDocuments.newer, storedEtag = "\"v2\"")
        val repo = repository(store)

        repo.load()

        assertEquals(ListSource.STORED, repo.summary.source)
        assertEquals(NEWER_VERSION, repo.summary.version)
        assertEquals(TEST_GENERATED_AT, repo.summary.generatedAt)
        assertEquals(TEST_CALL_NUMBERS.size, repo.summary.callNumbers)
        assertEquals(TEST_CALL_PREFIXES.size, repo.summary.callPrefixes)
        assertTrue(repo.matcher.shouldBlock(TEST_LIST_NUMBER))
        assertEquals("\"v2\"", store.storedEtag)
    }

    @Test
    fun onAVersionTieTheStoredListWinsAndKeepsItsEtag() {
        val store = FakeBlocklistStore(list = TestDocuments.seed, storedEtag = "\"seed\"")
        val repo = repository(store)

        repo.load()

        assertEquals(ListSource.STORED, repo.summary.source)
        assertEquals(SEED_VERSION, repo.summary.version)
        assertEquals("\"seed\"", store.storedEtag)
    }

    @Test
    fun aSeedNewerThanTheStoredListWinsAndClearsTheEtag() {
        // An app update can ship a seed newer than the list stored by the old version.
        val store = FakeBlocklistStore(list = TestDocuments.seedWithVersion(SEED_VERSION - 1), storedEtag = "\"old\"")
        val repo = repository(store)

        repo.load()

        assertEquals(ListSource.SEED, repo.summary.source)
        assertEquals(SEED_VERSION, repo.summary.version)
        assertNull(store.storedEtag)
    }

    @Test
    fun aCorruptStoredListFallsBackToTheSeedAndClearsTheEtag() {
        val store = FakeBlocklistStore(list = TestDocuments.corrupt, storedEtag = "\"v2\"")
        val repo = repository(store)

        repo.load()

        assertEquals(ListSource.SEED, repo.summary.source)
        assertEquals(SEED_VERSION, repo.summary.version)
        assertNull(store.storedEtag)
    }

    @Test
    fun aStoredSchema2ListIsIgnoredOnLoad() {
        val store = FakeBlocklistStore(list = TestDocuments.schema2, storedEtag = "\"v2\"")
        val repo = repository(store)

        repo.load()

        assertEquals(ListSource.SEED, repo.summary.source)
        assertNull(store.storedEtag)
    }

    @Test
    fun aStoredListIsUsedWhenTheSeedIsMissingInvalidOrThrows() {
        val seeds: List<() -> ByteArray?> = listOf(
            { null },
            { TestDocuments.corrupt },
            { throw IOException("asset missing") },
        )
        for (seed in seeds) {
            val store = FakeBlocklistStore(list = TestDocuments.newer, storedEtag = "\"v2\"")
            val repo = repository(store, seed)

            repo.load()

            assertEquals(ListSource.STORED, repo.summary.source)
            assertEquals(NEWER_VERSION, repo.summary.version)
            assertEquals("\"v2\"", store.storedEtag)
        }
    }

    @Test
    fun withNoValidListTheMatcherIsEmptyAndNothingThrows() {
        val seeds: List<() -> ByteArray?> = listOf(
            { null },
            { TestDocuments.corrupt },
            { throw IOException("asset missing") },
            { throw IllegalStateException("unexpected") },
        )
        for (seed in seeds) {
            val store = FakeBlocklistStore(list = TestDocuments.corrupt, storedEtag = "\"v2\"")
            val repo = repository(store, seed)

            repo.load()

            assertNone(repo)
            assertNull(store.storedEtag)
        }
    }

    @Test
    fun loadNeverThrowsEvenIfTheStoreDoes() {
        val store = FakeBlocklistStore(storedEtag = "\"v2\"").apply { readFailure = IllegalStateException("boom") }
        val repo = repository(store)

        repo.load()

        assertNone(repo)
        assertNull(store.storedEtag)
    }

    @Test
    fun reloadingAfterAFailedLoadRecovers() {
        val store = FakeBlocklistStore(list = TestDocuments.corrupt)
        val repo = repository(store, seed = { null })
        repo.load()
        assertNone(repo)

        store.list = TestDocuments.newer
        repo.load()

        assertEquals(ListSource.STORED, repo.summary.source)
        assertTrue(repo.matcher.shouldBlock(TEST_LIST_NUMBER))
    }

    // --- accept(): the version gate (AC-3, spec 6.1) ---

    @Test
    fun versionGateAcceptsTheOlderContractListThenTheNewer() {
        // AC-3: the unmodified seed and test lists, ordered by their real versions.
        val (older, newer) = TestDocuments.contractListsOlderFirst
        val store = FakeBlocklistStore()
        val repo = repository(store, seed = { null })
        repo.load()

        assertEquals(AcceptResult.ACCEPTED, repo.accept(older, "\"older\""))
        assertEquals(TestDocuments.versionOf(older), repo.summary.version)
        assertEquals(AcceptResult.ACCEPTED, repo.accept(newer, "\"newer\""))
        assertEquals(TestDocuments.versionOf(newer), repo.summary.version)
        assertEquals(ListSource.STORED, repo.summary.source)
        assertArrayEquals(newer, store.list)
        assertEquals("\"newer\"", store.storedEtag)
        assertEquals(2, store.writes)
    }

    @Test
    fun versionGateRejectsTheOlderContractListAfterTheNewer() {
        // AC-3: the same two lists in the reverse order.
        val (older, newer) = TestDocuments.contractListsOlderFirst
        val store = FakeBlocklistStore()
        val repo = repository(store, seed = { null })
        repo.load()

        assertEquals(AcceptResult.ACCEPTED, repo.accept(newer, "\"newer\""))
        assertEquals(AcceptResult.NOT_NEWER, repo.accept(older, "\"older\""))

        assertEquals(TestDocuments.versionOf(newer), repo.summary.version)
        assertArrayEquals(newer, store.list)
        assertEquals("\"newer\"", store.storedEtag)
        assertEquals(1, store.writes)
    }

    @Test
    fun versionGateRejectsAnEqualVersion() {
        val store = FakeBlocklistStore(list = TestDocuments.newer, storedEtag = "\"newer\"")
        val repo = repository(store)
        repo.load()

        assertEquals(AcceptResult.NOT_NEWER, repo.accept(TestDocuments.newer, "\"other\""))

        assertEquals("\"newer\"", store.storedEtag)
        assertEquals(0, store.writes)
    }

    @Test
    fun theSeedLoadedAtStartupIsAlsoGatedByVersion() {
        val store = FakeBlocklistStore()
        val repo = repository(store)
        repo.load()

        assertEquals(AcceptResult.NOT_NEWER, repo.accept(TestDocuments.seed, "\"seed\""))
        assertNull(store.storedEtag)
        assertEquals(ListSource.SEED, repo.summary.source)

        assertEquals(AcceptResult.ACCEPTED, repo.accept(TestDocuments.testWithVersion(SEED_VERSION + 1), null))
        assertEquals(SEED_VERSION + 1, repo.summary.version)
        assertEquals(ListSource.STORED, repo.summary.source)
        assertNull(store.storedEtag)
    }

    // --- accept(): rejection and storage failure (spec 7) ---

    @Test
    fun invalidDocumentsAreRejectedWholeAndTheCurrentListKept() {
        for (doc in listOf(TestDocuments.schema2, TestDocuments.extraKey, TestDocuments.corrupt, ByteArray(0))) {
            val store = FakeBlocklistStore()
            val repo = repository(store)
            repo.load()
            val before = repo.summary

            assertEquals(AcceptResult.REJECTED, repo.accept(doc, "\"bad\""))

            assertEquals(before, repo.summary)
            assertNull(store.storedEtag)
            assertNull(store.list)
            assertEquals(0, store.writes)
        }
    }

    @Test
    fun aStoreFailureKeepsTheCurrentListAndRetriesLater() {
        val store = FakeBlocklistStore().apply { writeFailure = IOException("disk full") }
        val repo = repository(store)
        repo.load()
        val matcher = repo.matcher

        assertEquals(AcceptResult.STORE_FAILED, repo.accept(TestDocuments.newer, "\"newer\""))

        assertSame(matcher, repo.matcher)
        assertEquals(ListSource.SEED, repo.summary.source)
        assertNull(store.storedEtag)
        assertFalse(repo.matcher.shouldBlock(TEST_LIST_NUMBER))

        store.writeFailure = null
        assertEquals(AcceptResult.ACCEPTED, repo.accept(TestDocuments.newer, "\"newer\""))
        assertEquals("\"newer\"", store.storedEtag)
        assertTrue(repo.matcher.shouldBlock(TEST_LIST_NUMBER))
    }

    @Test
    fun anAcceptedListWithoutAnEtagLeavesNoEtagStored() {
        val store = FakeBlocklistStore()
        val repo = repository(store)
        repo.load()

        assertEquals(AcceptResult.ACCEPTED, repo.accept(TestDocuments.newer, null))

        assertNull(store.storedEtag)
        assertArrayEquals(TestDocuments.newer, store.list)
    }

    @Test
    fun anAcceptedListIsWhatTheNextLoadReads() {
        val store = FakeBlocklistStore()
        repository(store).apply { load() }.accept(TestDocuments.newer, "\"newer\"")

        val restarted = repository(store)
        restarted.load()

        assertEquals(ListSource.STORED, restarted.summary.source)
        assertEquals(NEWER_VERSION, restarted.summary.version)
        assertEquals("\"newer\"", store.storedEtag)
    }
}
