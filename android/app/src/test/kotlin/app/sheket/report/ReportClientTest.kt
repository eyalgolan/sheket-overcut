package app.sheket.report

import app.sheket.BuildConfig
import app.sheket.screening.ScreenedCall
import app.sheket.screening.ScreenedCallCodec
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URL
import java.net.URLConnection
import java.net.URLStreamHandler
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Drives [ReportClient] against a local JDK [HttpServer] (#24 AC-2 to AC-5):
 * the exact request, the outcome for each status, the single retry, and the
 * refusal of numbers that are not E.164 or already reported.
 */
class ReportClientTest {

    private class Request(val method: String, val path: String, val contentType: String?, val body: ByteArray)

    private lateinit var server: HttpServer
    private lateinit var url: URL
    private val requests: MutableList<Request> = Collections.synchronizedList(mutableListOf())
    private val release = CountDownLatch(1)

    /** Statuses answered in order; the last one repeats. */
    @Volatile
    private var statuses: List<Int> = listOf(202)

    @Volatile
    private var responseBody: ByteArray? = null

    @Volatile
    private var handler: ((HttpExchange) -> Unit)? = null

    private val marked: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val installIdValue = UUID.randomUUID().toString()

    @Before
    fun setUp() {
        server = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        server.executor = Executors.newCachedThreadPool { r -> Thread(r, "test-http").apply { isDaemon = true } }
        server.createContext("/v1/reports") { exchange ->
            val index = requests.size
            requests += Request(
                exchange.requestMethod,
                exchange.requestURI.path,
                exchange.requestHeaders.getFirst("Content-Type"),
                exchange.requestBody.readBytes(),
            )
            try {
                val custom = handler
                if (custom != null) {
                    custom(exchange)
                } else {
                    respond(exchange, statuses[minOf(index, statuses.size - 1)], responseBody)
                }
            } catch (e: IOException) {
                // The client may hang up early, for example after a read timeout.
            } finally {
                exchange.close()
            }
        }
        server.start()
        url = URL("http://127.0.0.1:${server.address.port}/v1/reports")
    }

    @After
    fun tearDown() {
        release.countDown()
        server.stop(0)
        // A test that interrupts itself must not leak the flag into the next one.
        Thread.interrupted()
    }

    private fun respond(exchange: HttpExchange, status: Int, body: ByteArray?) {
        exchange.responseHeaders.add("Content-Type", "application/json")
        if (body == null) {
            exchange.sendResponseHeaders(status, -1)
        } else {
            exchange.sendResponseHeaders(status, body.size.toLong())
            exchange.responseBody.write(body)
        }
    }

    private fun client(
        target: URL = url,
        installId: () -> String = { installIdValue },
        isReported: (String) -> Boolean = { false },
        markReported: (String) -> Unit = { marked += it },
        appVersion: String = "1.0.0",
        readTimeoutMs: Int = 2_000,
        retryDelayMs: Long = 10,
    ) = ReportClient(
        installId = installId,
        isReported = isReported,
        markReported = markReported,
        url = target,
        appVersion = appVersion,
        connectTimeoutMs = 2_000,
        readTimeoutMs = readTimeoutMs,
        retryDelayMs = retryDelayMs,
    )

    private fun bodyOf(request: Request): JsonObject =
        Json.parseToJsonElement(String(request.body, Charsets.UTF_8)).jsonObject

    // --- The request (AC-2, AC-3, REQ-2) ---

    @Test
    fun requestIsAPostOfTheExactJsonBody() {
        assertEquals(ReportOutcome.Sent, client().send(NUMBER))

        assertEquals(1, requests.size)
        val request = requests.single()
        assertEquals("POST", request.method)
        assertEquals("/v1/reports", request.path)
        val expected = """{"install_id":"$installIdValue","platform":"android","kind":"call",""" +
            """"sender":"$NUMBER","app_version":"1.0.0"}"""
        assertEquals(expected, String(request.body, Charsets.UTF_8))
    }

    @Test
    fun bodyHasExactlyTheFiveKeysAndNoText() {
        client().send(NUMBER)

        val body = bodyOf(requests.single())
        assertEquals(setOf("install_id", "platform", "kind", "sender", "app_version"), body.keys)
        assertFalse("a call report must not carry text", "text" in body)
        for ((key, value) in body) {
            assertTrue("$key must be a JSON string", value is JsonPrimitive && value.isString)
        }
        assertEquals("android", (body.getValue("platform") as JsonPrimitive).content)
        assertEquals("call", (body.getValue("kind") as JsonPrimitive).content)
        assertEquals(NUMBER, (body.getValue("sender") as JsonPrimitive).content)
    }

    @Test
    fun contentTypeIsApplicationJson() {
        client().send(NUMBER)

        assertEquals("application/json", requests.single().contentType)
    }

    @Test
    fun sentInstallIdIsALowercase36CharacterUuid() {
        // The production source of the ID: a random UUID, as InstallId creates it.
        client(installId = { UUID.randomUUID().toString() }).send(NUMBER)

        val sent = (bodyOf(requests.single()).getValue("install_id") as JsonPrimitive).content
        assertEquals(36, sent.length)
        assertTrue("not the form _parse_install_id accepts: $sent", BACKEND_INSTALL_ID.matches(sent))
        assertTrue(InstallId.isCanonical(sent))
    }

    @Test
    fun defaultAppVersionIsTheBuildVersionAndMatchesTheBackendPattern() {
        val c = ReportClient(
            installId = { installIdValue },
            isReported = { false },
            markReported = { marked += it },
            url = url,
            retryDelayMs = 10,
        )
        assertEquals(ReportOutcome.Sent, c.send(NUMBER))

        val sent = (bodyOf(requests.single()).getValue("app_version") as JsonPrimitive).content
        assertEquals(BuildConfig.VERSION_NAME, sent)
        assertTrue("app_version $sent does not match the backend pattern", BACKEND_APP_VERSION.matches(sent))
    }

    @Test
    fun defaultTimeoutsAreTenSecondsConnectAndFifteenSecondsRead() {
        assertEquals(10_000, ReportClient.CONNECT_TIMEOUT_MS)
        assertEquals(15_000, ReportClient.READ_TIMEOUT_MS)
        assertTrue(ReportClient.RETRY_DELAY_MS in 1_000L..3_000L)

        // The defaults are actually applied to the connection.
        val counting = CountingUrl(url)
        val c = ReportClient(
            installId = { installIdValue },
            isReported = { false },
            markReported = { marked += it },
            url = counting.url,
        )
        assertEquals(ReportOutcome.Sent, c.send(NUMBER))
        val conn = counting.connections.single()
        assertEquals(10_000, conn.connectTimeout)
        assertEquals(15_000, conn.readTimeout)
    }

    @Test
    fun defaultReportUrlIsHttps() {
        assertTrue(BuildConfig.REPORT_URL.startsWith("https://"))
    }

    // --- Outcomes (AC-2, AC-5, REQ-3, REQ-4) ---

    @Test
    fun accepted202IsSentAndMarksTheNumberReported() {
        assertEquals(ReportOutcome.Sent, client().send(NUMBER))

        assertEquals(1, requests.size)
        assertEquals(listOf(NUMBER), marked)
    }

    @Test
    fun rateLimited429IsNotRetried() {
        statuses = listOf(429)

        assertEquals(ReportOutcome.RateLimited, client().send(NUMBER))

        assertEquals(1, requests.size)
        assertTrue(marked.isEmpty())
    }

    @Test
    fun twoServerErrorsGiveNotSentAfterExactlyTwoRequests() {
        statuses = listOf(503, 503)

        assertEquals(ReportOutcome.NotSent(), client().send(NUMBER))

        assertEquals(2, requests.size)
        assertTrue(marked.isEmpty())
    }

    @Test
    fun serverErrorIsRetriedOnlyOnce() {
        statuses = listOf(500)

        assertEquals(ReportOutcome.NotSent(), client().send(NUMBER))

        assertEquals(2, requests.size)
    }

    @Test
    fun serverErrorThenAcceptedIsSent() {
        statuses = listOf(503, 202)

        assertEquals(ReportOutcome.Sent, client().send(NUMBER))

        assertEquals(2, requests.size)
        assertEquals(listOf(NUMBER), marked)
        // The retry sends the same body.
        assertEquals(String(requests[0].body, Charsets.UTF_8), String(requests[1].body, Charsets.UTF_8))
    }

    @Test
    fun serverErrorThenRateLimitedIsRateLimited() {
        statuses = listOf(502, 429)

        assertEquals(ReportOutcome.RateLimited, client().send(NUMBER))

        assertEquals(2, requests.size)
    }

    @Test
    fun retryWaitsForTheRetryDelay() {
        statuses = listOf(503, 503)

        val started = System.nanoTime()
        client(retryDelayMs = 300).send(NUMBER)
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

        assertEquals(2, requests.size)
        assertTrue("retry came after $elapsedMs ms", elapsedMs >= 300)
    }

    @Test
    fun badRequest400IsNotSentWithTheErrorFieldAndNotRetried() {
        statuses = listOf(400)
        responseBody = """{"error":"text"}""".toByteArray(Charsets.UTF_8)

        assertEquals(ReportOutcome.NotSent("text"), client().send(NUMBER))

        assertEquals(1, requests.size)
        assertTrue(marked.isEmpty())
    }

    @Test
    fun badRequestWithoutAUsableErrorFieldHasNoErrorField() {
        val bodies = listOf(
            null,
            "".toByteArray(),
            "not json".toByteArray(),
            """{"error":42}""".toByteArray(),
            """{"error":null}""".toByteArray(),
            """{"error":{"field":"x"}}""".toByteArray(),
            """["error"]""".toByteArray(),
            """{"other":"x"}""".toByteArray(),
        )
        statuses = listOf(400)
        for (body in bodies) {
            requests.clear()
            responseBody = body
            assertEquals("body ${body?.let { String(it) }}", ReportOutcome.NotSent(null), client().send(NUMBER))
            assertEquals(1, requests.size)
        }
    }

    @Test
    fun badRequestBodyIsReadOnlyUpToOneKibibyte() {
        statuses = listOf(400)
        // A valid document whose closing brace is beyond the cap: truncated, so no field.
        responseBody = ("""{"error":"text","pad":"""" + "x".repeat(2_000) + "\"}").toByteArray()

        assertEquals(ReportOutcome.NotSent(null), client().send(NUMBER))
        assertEquals(1, requests.size)
    }

    @Test
    fun otherStatusesAreNotSentWithoutRetry() {
        for (status in listOf(200, 201, 204, 301, 302, 401, 403, 404, 413)) {
            requests.clear()
            statuses = listOf(status)
            handler = if (status in 300..399) {
                { ex ->
                    // A redirect back to the same endpoint must not be followed.
                    ex.responseHeaders.add("Location", url.toString())
                    ex.sendResponseHeaders(status, -1)
                }
            } else {
                null
            }
            assertEquals("status $status", ReportOutcome.NotSent(), client().send(NUMBER))
            assertEquals("requests for status $status", 1, requests.size)
        }
        assertTrue(marked.isEmpty())
    }

    @Test
    fun connectionRefusedIsNotSentAfterTwoAttempts() {
        val closedPort = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val counting = CountingUrl(URL("http://127.0.0.1:$closedPort/v1/reports"))

        assertEquals(ReportOutcome.NotSent(), client(target = counting.url).send(NUMBER))

        assertEquals(2, counting.attempts.get())
        assertTrue(marked.isEmpty())
    }

    @Test
    fun connectionDroppedWithoutResponseIsRetriedOnce() {
        val accepted = AtomicInteger()
        ServerSocket(0, 50, InetAddress.getLoopbackAddress()).use { socket ->
            val acceptor = Thread {
                try {
                    while (true) {
                        socket.accept().close()
                        accepted.incrementAndGet()
                    }
                } catch (e: IOException) {
                    // Closed at the end of the test.
                }
            }.apply { isDaemon = true; start() }

            val target = URL("http://127.0.0.1:${socket.localPort}/v1/reports")
            assertEquals(ReportOutcome.NotSent(), client(target = target).send(NUMBER))
            socket.close()
            acceptor.join(2_000)
        }
        assertEquals(2, accepted.get())
    }

    @Test
    fun readTimeoutIsRetriedOnceThenNotSent() {
        handler = { ex ->
            release.await(5, TimeUnit.SECONDS)
            respond(ex, 202, null)
        }

        assertEquals(ReportOutcome.NotSent(), client(readTimeoutMs = 200).send(NUMBER))

        assertEquals(2, requests.size)
        assertTrue(marked.isEmpty())
    }

    @Test
    fun interruptDuringTheRetryDelayGivesNotSentAndKeepsTheFlag() {
        statuses = listOf(503)
        val c = client(retryDelayMs = 5_000)
        Thread.currentThread().interrupt()

        val outcome = c.send(NUMBER)

        assertTrue("interrupt flag must be restored", Thread.interrupted())
        assertEquals(ReportOutcome.NotSent(), outcome)
        assertEquals(1, requests.size)
    }

    // --- Refusal (AC-4) and failure containment ---

    @Test
    fun numbersThatAreNotE164AreRefusedWithoutARequest() {
        var idCalls = 0
        val c = client(installId = { idCalls++; installIdValue })
        for (number in listOf("", "+", "0501234567", "972501234567", "+0501234567", "+97250", "abc", " +972501234567")) {
            assertEquals("number '$number'", ReportOutcome.Refused, c.send(number))
        }
        assertEquals(0, requests.size)
        assertEquals(0, idCalls)
        assertTrue(marked.isEmpty())
    }

    @Test
    fun alreadyReportedNumberIsRefusedWithoutARequest() {
        val asked = mutableListOf<String>()
        val c = client(isReported = { asked += it; true })

        assertEquals(ReportOutcome.Refused, c.send(NUMBER))

        assertEquals(listOf(NUMBER), asked)
        assertEquals(0, requests.size)
    }

    @Test
    fun failingInstallIdGivesNotSentWithoutARequest() {
        val c = client(installId = { throw IllegalStateException("prefs") })

        assertEquals(ReportOutcome.NotSent(), c.send(NUMBER))
        assertEquals(0, requests.size)
    }

    @Test
    fun failingIsReportedGivesNotSentWithoutARequest() {
        val c = client(isReported = { throw IOException("log") })

        assertEquals(ReportOutcome.NotSent(), c.send(NUMBER))
        assertEquals(0, requests.size)
    }

    @Test
    fun failingMarkReportedStillGivesSent() {
        val c = client(markReported = { throw IOException("disk full") })

        assertEquals(ReportOutcome.Sent, c.send(NUMBER))
        assertEquals(1, requests.size)
    }

    @Test
    fun afterSentEveryEntryWithTheNumberIsReportedAndNoSecondRequestIsMade() {
        // The production wiring in SheketApp, over an in-memory log.
        var log = listOf(
            ScreenedCall("a", NUMBER, 3_000, blocked = true, reported = false),
            ScreenedCall("b", OTHER, 2_000, blocked = false, reported = false),
            ScreenedCall("c", NUMBER, 1_000, blocked = false, reported = false),
            ScreenedCall("d", null, 500, blocked = false, reported = false),
        )
        val c = client(
            isReported = { n -> log.any { it.number == n && it.reported } },
            markReported = { n -> log = ScreenedCallCodec.markReported(log, n) },
        )

        assertEquals(ReportOutcome.Sent, c.send(NUMBER))
        assertEquals(mapOf("a" to true, "b" to false, "c" to true, "d" to false), log.associate { it.id to it.reported })

        // A second tap on the other row with the same number makes no request.
        assertEquals(ReportOutcome.Refused, c.send(NUMBER))
        assertEquals(1, requests.size)

        // A different number is still reportable.
        assertEquals(ReportOutcome.Sent, c.send(OTHER))
        assertEquals(2, requests.size)
        assertTrue(log.filter { it.number != null }.all { it.reported })
    }

    @Test
    fun nothingIsQueuedAfterAFailedReport() {
        statuses = listOf(503, 503, 202)
        val c = client()

        assertEquals(ReportOutcome.NotSent(), c.send(NUMBER))
        assertEquals(2, requests.size)

        // A later, unrelated report sends only its own body: the dropped one is not replayed.
        assertEquals(ReportOutcome.Sent, c.send(OTHER))
        assertEquals(3, requests.size)
        assertEquals(OTHER, (bodyOf(requests.last()).getValue("sender") as JsonPrimitive).content)
        assertEquals(listOf(OTHER), marked)
    }

    /** A URL to [target] that counts connection attempts and keeps each connection. */
    private class CountingUrl(target: URL) {
        val attempts = AtomicInteger()
        val connections: MutableList<HttpURLConnection> = Collections.synchronizedList(mutableListOf())
        val url: URL = URL(
            null,
            target.toString(),
            object : URLStreamHandler() {
                override fun openConnection(u: URL): URLConnection {
                    attempts.incrementAndGet()
                    return (URL(u.toString()).openConnection() as HttpURLConnection).also { connections += it }
                }
            },
        )
    }

    private companion object {
        const val NUMBER = "+972501234567"
        const val OTHER = "+972521234567"

        // backend/src/sheket/report.py: _parse_install_id accepts only the
        // canonical lowercase hyphenated form, and _APP_VERSION is fullmatched.
        val BACKEND_INSTALL_ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        val BACKEND_APP_VERSION = Regex("[0-9A-Za-z.+\\-]{1,32}")
    }
}
