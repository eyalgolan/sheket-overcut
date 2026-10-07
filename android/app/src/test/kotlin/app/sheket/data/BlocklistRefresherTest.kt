package app.sheket.data

import app.sheket.data.TestDocuments.NEWER_VERSION
import app.sheket.data.TestDocuments.SEED_VERSION
import app.sheket.data.TestDocuments.TEST_LIST_NUMBER
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URL
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Drives [BlocklistRefresher]'s HTTP handling against a local JDK [HttpServer]
 * (AC-2). The store is the in-memory fake; the repository and refresher are the
 * production classes.
 */
class BlocklistRefresherTest {

    private class Request(val method: String, val accept: String?, val ifNoneMatch: String?)

    private lateinit var server: HttpServer
    private lateinit var url: URL
    private val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    private val release = CountDownLatch(1)

    @Volatile
    private var handler: (HttpExchange) -> Unit = { respond(it, 500) }

    private var clock = 1_000L
    private val now: () -> Long = { clock }

    private lateinit var store: FakeBlocklistStore
    private lateinit var repository: BlocklistRepository

    @Before
    fun setUp() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.executor = Executors.newCachedThreadPool { r -> Thread(r, "test-http").apply { isDaemon = true } }
        server.createContext("/v1/blocklist.json") { exchange ->
            requests += Request(
                exchange.requestMethod,
                exchange.requestHeaders.getFirst("Accept"),
                exchange.requestHeaders.getFirst("If-None-Match"),
            )
            try {
                handler(exchange)
            } catch (e: IOException) {
                // The client may hang up early, for example on an oversized body.
            } finally {
                exchange.close()
            }
        }
        server.start()
        url = URL("http://127.0.0.1:${server.address.port}/v1/blocklist.json")

        // A fresh install: the seed is in memory and no ETag is stored.
        store = FakeBlocklistStore()
        repository = BlocklistRepository(store) { TestDocuments.seed }
        repository.load()
    }

    @After
    fun tearDown() {
        release.countDown()
        server.stop(0)
    }

    private fun refresher(readTimeoutMs: Int = 5_000) = BlocklistRefresher(
        repository = repository,
        store = store,
        url = url,
        connectTimeoutMs = 5_000,
        readTimeoutMs = readTimeoutMs,
        now = now,
    )

    private fun respond(exchange: HttpExchange, status: Int, body: ByteArray? = null, etag: String? = null) {
        etag?.let { exchange.responseHeaders.add("ETag", it) }
        exchange.responseHeaders.add("Content-Type", "application/json")
        if (body == null) {
            exchange.sendResponseHeaders(status, -1)
        } else {
            exchange.sendResponseHeaders(status, body.size.toLong())
            exchange.responseBody.write(body)
        }
    }

    /** Sends [body] with chunked transfer encoding, so the client sees no Content-Length. */
    private fun respondChunked(exchange: HttpExchange, body: ByteArray) {
        exchange.sendResponseHeaders(200, 0)
        exchange.responseBody.write(body)
    }

    /** [doc] followed by JSON whitespace, [size] bytes in total; still a valid document. */
    private fun padded(doc: ByteArray, size: Int): ByteArray {
        check(size >= doc.size)
        return doc + ByteArray(size - doc.size) { ' '.code.toByte() }
    }

    private fun assertUnchangedSeed() {
        assertEquals(ListSource.SEED, repository.summary.source)
        assertEquals(SEED_VERSION, repository.summary.version)
        assertFalse(repository.matcher.shouldBlock(TEST_LIST_NUMBER))
        assertNull(store.list)
        assertEquals(0, store.writes)
    }

    // --- The request ---

    @Test
    fun sendsAGetAcceptingJsonWithoutIfNoneMatchWhenNoEtagIsStored() {
        refresher().refresh()

        assertEquals(1, requests.size)
        assertEquals("GET", requests[0].method)
        assertEquals("application/json", requests[0].accept)
        assertNull(requests[0].ifNoneMatch)
    }

    @Test
    fun sendsTheStoredEtagAsIfNoneMatch() {
        store.storedEtag = "\"abc\""

        refresher().refresh()

        assertEquals("\"abc\"", requests.single().ifNoneMatch)
    }

    @Test
    fun productionDefaultsMatchTheDesign() {
        assertEquals(10_000, BlocklistRefresher.CONNECT_TIMEOUT_MS)
        assertEquals(15_000, BlocklistRefresher.READ_TIMEOUT_MS)
        assertEquals(5 * 1024 * 1024, BlocklistRefresher.MAX_BODY_BYTES)
    }

    // --- 304 ---

    @Test
    fun notModifiedRecordsSuccessAndDoesNotChangeTheList() {
        store.storedEtag = "\"seed\""
        handler = { respond(it, 304) }

        assertEquals(RefreshOutcome.NOT_MODIFIED, refresher().refresh())

        assertEquals(1_000L, store.lastSuccess)
        assertEquals("\"seed\"", store.storedEtag)
        assertUnchangedSeed()
    }

    // --- 200 ---

    @Test
    fun newerListRecordsSuccessStoresTheEtagAndSwapsTheMatcher() {
        handler = { respond(it, 200, TestDocuments.newer, etag = "\"v2\"") }

        assertEquals(RefreshOutcome.UPDATED, refresher().refresh())

        assertEquals(1_000L, store.lastSuccess)
        assertEquals("\"v2\"", store.storedEtag)
        assertArrayEquals(TestDocuments.newer, store.list)
        assertEquals(ListSource.STORED, repository.summary.source)
        assertEquals(NEWER_VERSION, repository.summary.version)
        assertTrue(repository.matcher.shouldBlock(TEST_LIST_NUMBER))
    }

    @Test
    fun aValidListThatIsNotNewerRecordsSuccessAndDoesNotStoreTheEtag() {
        handler = { respond(it, 200, TestDocuments.seed, etag = "\"seed\"") }

        assertEquals(RefreshOutcome.NOT_NEWER, refresher().refresh())

        assertEquals(1_000L, store.lastSuccess)
        assertNull(store.storedEtag)
        assertUnchangedSeed()
    }

    @Test
    fun anOlderListKeepsTheStoredListAndItsEtag() {
        handler = { respond(it, 200, TestDocuments.newer, etag = "\"v2\"") }
        refresher().refresh()
        clock = 2_000L
        handler = { respond(it, 200, TestDocuments.seed, etag = "\"seed\"") }

        assertEquals(RefreshOutcome.NOT_NEWER, refresher().refresh())

        assertEquals(2_000L, store.lastSuccess)
        assertEquals("\"v2\"", store.storedEtag)
        assertEquals(NEWER_VERSION, repository.summary.version)
        assertEquals(1, store.writes)
    }

    @Test
    fun schema2RecordsNoSuccessAndLeavesTheEtagUnchanged() {
        store.storedEtag = "\"kept\""
        handler = { respond(it, 200, TestDocuments.schema2, etag = "\"v3\"") }

        assertEquals(RefreshOutcome.REJECTED, refresher().refresh())

        assertNull(store.lastSuccess)
        assertEquals("\"kept\"", store.storedEtag)
        assertUnchangedSeed()
    }

    @Test
    fun anExtraKeyRecordsNoSuccessAndLeavesTheEtagUnchanged() {
        store.storedEtag = "\"kept\""
        handler = { respond(it, 200, TestDocuments.extraKey, etag = "\"v3\"") }

        assertEquals(RefreshOutcome.REJECTED, refresher().refresh())

        assertNull(store.lastSuccess)
        assertEquals("\"kept\"", store.storedEtag)
        assertUnchangedSeed()
    }

    @Test
    fun aMalformedBodyIsRejected() {
        handler = { respond(it, 200, TestDocuments.corrupt, etag = "\"v3\"") }

        assertEquals(RefreshOutcome.REJECTED, refresher().refresh())

        assertNull(store.lastSuccess)
        assertNull(store.storedEtag)
        assertUnchangedSeed()
    }

    @Test
    fun aListThatCannotBeStoredRecordsNoSuccess() {
        store.writeFailure = IOException("disk full")
        handler = { respond(it, 200, TestDocuments.newer, etag = "\"v2\"") }

        assertEquals(RefreshOutcome.FAILED, refresher().refresh())

        assertNull(store.lastSuccess)
        assertNull(store.storedEtag)
        assertUnchangedSeed()
    }

    // --- The 5 MiB cap ---

    @Test
    fun aBodyOverTheCapWithContentLengthIsRejected() {
        val body = padded(TestDocuments.newer, BlocklistRefresher.MAX_BODY_BYTES + 1)
        handler = { respond(it, 200, body, etag = "\"big\"") }

        assertEquals(RefreshOutcome.REJECTED, refresher().refresh())

        assertNull(store.lastSuccess)
        assertNull(store.storedEtag)
        assertUnchangedSeed()
    }

    @Test
    fun aChunkedBodyOverTheCapIsRejected() {
        val body = padded(TestDocuments.newer, BlocklistRefresher.MAX_BODY_BYTES + 1)
        handler = { respondChunked(it, body) }

        assertEquals(RefreshOutcome.REJECTED, refresher().refresh())

        assertNull(store.lastSuccess)
        assertUnchangedSeed()
    }

    @Test
    fun aChunkedBodyOfExactlyTheCapIsAccepted() {
        val body = padded(TestDocuments.newer, BlocklistRefresher.MAX_BODY_BYTES)
        handler = { respondChunked(it, body) }

        assertEquals(RefreshOutcome.UPDATED, refresher().refresh())

        assertEquals(NEWER_VERSION, repository.summary.version)
        assertEquals(BlocklistRefresher.MAX_BODY_BYTES, store.list!!.size)
    }

    // --- Failures keep everything as it is ---

    @Test
    fun otherStatusesRecordNothing() {
        store.storedEtag = "\"kept\""
        for (status in listOf(500, 503, 404, 204)) {
            handler = { respond(it, status, if (status == 204) null else TestDocuments.newer, etag = "\"v2\"") }

            assertEquals("status $status", RefreshOutcome.FAILED, refresher().refresh())

            assertNull(store.lastSuccess)
            assertEquals("\"kept\"", store.storedEtag)
            assertUnchangedSeed()
        }
    }

    @Test
    fun aConnectionFailureRecordsNothing() {
        val closedPort = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val refresher = BlocklistRefresher(
            repository = repository,
            store = store,
            url = URL("http://127.0.0.1:$closedPort/v1/blocklist.json"),
            connectTimeoutMs = 2_000,
            readTimeoutMs = 2_000,
            now = now,
        )

        assertEquals(RefreshOutcome.FAILED, refresher.refresh())

        assertNull(store.lastSuccess)
        assertUnchangedSeed()
    }

    @Test
    fun anUnresolvableHostRecordsNothing() {
        // The default build-time URL uses the reserved .invalid TLD (RFC 6761).
        val refresher = BlocklistRefresher(
            repository = repository,
            store = store,
            url = URL("https://blocklist.example.invalid/v1/blocklist.json"),
            connectTimeoutMs = 2_000,
            readTimeoutMs = 2_000,
            now = now,
        )

        assertEquals(RefreshOutcome.FAILED, refresher.refresh())

        assertNull(store.lastSuccess)
        assertUnchangedSeed()
    }

    @Test
    fun aReadTimeoutRecordsNothing() {
        handler = { exchange ->
            release.await(10, TimeUnit.SECONDS)
            respond(exchange, 200, TestDocuments.newer, etag = "\"v2\"")
        }

        val started = System.nanoTime()
        assertEquals(RefreshOutcome.FAILED, refresher(readTimeoutMs = 300).refresh())
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

        assertTrue("timed out after $elapsedMs ms", elapsedMs < 5_000)
        assertNull(store.lastSuccess)
        assertUnchangedSeed()
    }

    @Test
    fun aTimeoutMidBodyRecordsNothing() {
        handler = { exchange ->
            exchange.sendResponseHeaders(200, TestDocuments.newer.size.toLong())
            exchange.responseBody.write(TestDocuments.newer, 0, 10)
            exchange.responseBody.flush()
            release.await(10, TimeUnit.SECONDS)
        }

        assertEquals(RefreshOutcome.FAILED, refresher(readTimeoutMs = 300).refresh())

        assertNull(store.lastSuccess)
        assertUnchangedSeed()
    }

    // --- Flow and serialisation ---

    @Test
    fun afterAnUpdateTheNextRequestIsConditionalAndA304IsASuccess() {
        handler = { exchange ->
            if (exchange.requestHeaders.getFirst("If-None-Match") == "\"v2\"") {
                respond(exchange, 304)
            } else {
                respond(exchange, 200, TestDocuments.newer, etag = "\"v2\"")
            }
        }
        val refresher = refresher()

        assertEquals(RefreshOutcome.UPDATED, refresher.refresh())
        clock = 2_000L
        assertEquals(RefreshOutcome.NOT_MODIFIED, refresher.refresh())

        assertEquals(listOf(null, "\"v2\""), requests.map { it.ifNoneMatch })
        assertEquals(2_000L, store.lastSuccess)
        assertEquals(NEWER_VERSION, repository.summary.version)
    }

    @Test
    fun refreshesAreSerialised() {
        val inFlight = AtomicInteger()
        val maxInFlight = AtomicInteger()
        handler = { exchange ->
            maxInFlight.accumulateAndGet(inFlight.incrementAndGet(), ::maxOf)
            Thread.sleep(150)
            inFlight.decrementAndGet()
            respond(exchange, 304)
        }
        val refresher = refresher()
        val pool = Executors.newFixedThreadPool(3)
        try {
            val results = (1..3)
                .map { pool.submit<RefreshOutcome> { refresher.refresh() } }
                .map { it.get(10, TimeUnit.SECONDS) }

            assertEquals(List(3) { RefreshOutcome.NOT_MODIFIED }, results)
            assertEquals(3, requests.size)
            assertEquals(1, maxInFlight.get())
        } finally {
            pool.shutdownNow()
        }
    }
}
