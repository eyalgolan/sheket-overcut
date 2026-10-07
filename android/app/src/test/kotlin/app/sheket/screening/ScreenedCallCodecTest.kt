package app.sheket.screening

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The screened-call log encoding and queries (AC-2), with no Android types involved. */
class ScreenedCallCodecTest {

    private fun call(
        i: Int,
        number: String? = "+97255500%04d".format(i),
        blocked: Boolean = true,
        reported: Boolean = false,
        at: Long = 1_791_201_600_000L + i,
    ) = ScreenedCall(id = "id-$i", number = number, at = at, blocked = blocked, reported = reported)

    private fun decode(json: String) = ScreenedCallCodec.decode(json.toByteArray(Charsets.UTF_8))

    private val validEntry = """{"id":"a","number":"+972555001234","at":1,"blocked":true,"reported":false}"""

    // --- Round trip ---

    @Test
    fun entriesRoundTrip() {
        val entries = listOf(
            call(1),
            call(2, number = null, blocked = false),
            call(3, reported = true),
            call(4, number = "unknown", blocked = false),
            ScreenedCall(id = "max", number = "+972555009876", at = Long.MAX_VALUE, blocked = true, reported = true),
            ScreenedCall(id = "neg", number = "+972555009876", at = -1L, blocked = false, reported = false),
        )
        assertEquals(entries, ScreenedCallCodec.decode(ScreenedCallCodec.encode(entries)))
    }

    @Test
    fun emptyLogRoundTrips() {
        val bytes = ScreenedCallCodec.encode(emptyList())
        assertEquals("[]", bytes.toString(Charsets.UTF_8))
        assertEquals(emptyList<ScreenedCall>(), ScreenedCallCodec.decode(bytes))
    }

    @Test
    fun encodingIsAJsonArrayOfObjectsWithTheFiveKeys() {
        val root = Json.parseToJsonElement(
            ScreenedCallCodec.encode(listOf(call(1), call(2, number = null))).toString(Charsets.UTF_8),
        ) as JsonArray
        assertEquals(2, root.size)
        for (item in root) {
            assertEquals(setOf("id", "number", "at", "blocked", "reported"), (item as JsonObject).keys)
        }
        assertEquals(JsonNull, (root[1] as JsonObject)["number"])
    }

    @Test
    fun decodeKeepsTheStoredOrder() {
        val entries = (1..5).map { call(it) }
        assertEquals(entries.map { it.id }, ScreenedCallCodec.decode(ScreenedCallCodec.encode(entries)).map { it.id })
    }

    // --- 200-entry cap ---

    @Test
    fun the201stEntryDropsTheOldest() {
        // Newest first: call(200) is the newest, call(1) the oldest.
        var log = emptyList<ScreenedCall>()
        for (i in 1..ScreenedCallCodec.MAX_ENTRIES) log = ScreenedCallCodec.prepend(log, call(i))
        assertEquals(200, log.size)
        assertEquals("id-1", log.last().id)

        log = ScreenedCallCodec.prepend(log, call(201))

        assertEquals(200, log.size)
        assertEquals("id-201", log.first().id)
        assertEquals("id-2", log.last().id)
        assertFalse(log.any { it.id == "id-1" })
        assertEquals(log, ScreenedCallCodec.decode(ScreenedCallCodec.encode(log)))
    }

    @Test
    fun prependAddsAsNewest() {
        val log = ScreenedCallCodec.prepend(listOf(call(1)), call(2))
        assertEquals(listOf("id-2", "id-1"), log.map { it.id })
    }

    @Test
    fun decodeKeepsAtMostTheNewest200() {
        val entries = (1..250).map { call(it) }
        val decoded = ScreenedCallCodec.decode(ScreenedCallCodec.encode(entries))
        assertEquals(200, decoded.size)
        assertEquals(entries.take(200), decoded)
    }

    // --- Corrupt input reads as empty ---

    @Test
    fun corruptJsonGivesAnEmptyLog() {
        for (text in listOf("", "   ", "{", "[", "[{", "not json", "[$validEntry", "$validEntry]", "[$validEntry,]")) {
            assertEquals("input '$text'", emptyList<ScreenedCall>(), decode(text))
        }
    }

    @Test
    fun nullInputGivesAnEmptyLog() {
        assertEquals(emptyList<ScreenedCall>(), ScreenedCallCodec.decode(null))
    }

    @Test
    fun invalidUtf8GivesAnEmptyLog() {
        val bytes = "[$validEntry]".toByteArray(Charsets.UTF_8) + byteArrayOf(0xC3.toByte())
        assertEquals(emptyList<ScreenedCall>(), ScreenedCallCodec.decode(bytes))
    }

    @Test
    fun rootThatIsNotAnArrayGivesAnEmptyLog() {
        for (text in listOf(validEntry, "null", "1", "\"[]\"", "true")) {
            assertEquals("input '$text'", emptyList<ScreenedCall>(), decode(text))
        }
    }

    @Test
    fun deeplyNestedJsonGivesAnEmptyLogInsteadOfThrowing() {
        assertEquals(emptyList<ScreenedCall>(), decode("[".repeat(10_000) + "]".repeat(10_000)))
    }

    @Test
    fun oneMalformedEntryRejectsTheWholeFile() {
        val bad = listOf(
            """null""",
            """[]""",
            """"a"""",
            """{"number":"+972555001234","at":1,"blocked":true,"reported":false}""",
            """{"id":"","number":"+972555001234","at":1,"blocked":true,"reported":false}""",
            """{"id":1,"number":"+972555001234","at":1,"blocked":true,"reported":false}""",
            """{"id":"a","at":1,"blocked":true,"reported":false}""",
            """{"id":"a","number":972555001234,"at":1,"blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":"1","blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":1.5,"blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":1e3,"blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":null,"blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":99999999999999999999,"blocked":true,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":1,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":1,"blocked":"true","reported":false}""",
            """{"id":"a","number":"+972555001234","at":1,"blocked":1,"reported":false}""",
            """{"id":"a","number":"+972555001234","at":1,"blocked":true}""",
            """{"id":"a","number":"+972555001234","at":1,"blocked":true,"reported":null}""",
        )
        for (entry in bad) {
            assertEquals(entry, emptyList<ScreenedCall>(), decode("[$validEntry,$entry]"))
        }
    }

    @Test
    fun unknownKeysAreIgnored() {
        val decoded = decode("""[{"id":"a","number":null,"at":1,"blocked":false,"reported":false,"extra":[1]}]""")
        assertEquals(listOf(ScreenedCall("a", null, 1, blocked = false, reported = false)), decoded)
    }

    // --- Non-E.164 numbers are kept but not reportable ---

    @Test
    fun nonE164NumbersAreKeptButFlaggedNotReportable() {
        val stored = listOf(
            call(1, number = "unknown", blocked = false),
            call(2, number = "0555001234", blocked = false),
            call(3, number = "+97255", blocked = false),
            call(4, number = null, blocked = false),
        )
        val decoded = ScreenedCallCodec.decode(ScreenedCallCodec.encode(stored))
        assertEquals(stored, decoded)
        assertTrue(decoded.none { it.reportable })
    }

    @Test
    fun e164NumbersAreReportable() {
        assertTrue(call(1, number = "+972555001234").reportable)
    }

    // --- Queries used by #23 and #24 ---

    @Test
    fun markReportedFlagsEveryEntryWithThatNumberOnly() {
        val log = listOf(
            call(1, number = "+972555001234"),
            call(2, number = "+972555009876"),
            call(3, number = "+972555001234", blocked = false),
            call(4, number = null),
        )
        val updated = ScreenedCallCodec.markReported(log, "+972555001234")
        assertEquals(listOf(true, false, true, false), updated.map { it.reported })
        assertEquals(log.map { it.copy(reported = false) }, updated.map { it.copy(reported = false) })
    }

    @Test
    fun markReportedWithNoMatchLeavesTheLogEqual() {
        val log = listOf(call(1), call(2))
        assertEquals(log, ScreenedCallCodec.markReported(log, "+972555000000"))
    }

    // --- Reported by number (#57) ---

    @Test
    fun reportedNumbersOfAnEmptyLogIsEmpty() {
        assertEquals(emptySet<String>(), ScreenedCallCodec.reportedNumbers(emptyList()))
    }

    @Test
    fun reportedNumbersHoldsEachReportedNumberOnce() {
        val log = listOf(
            call(1, number = "+972555001234", reported = true),
            call(2, number = "+972555009876"),
            call(3, number = "+972555001234", reported = true),
            call(4, number = "+972555004321", blocked = false, reported = true),
        )
        assertEquals(setOf("+972555001234", "+972555004321"), ScreenedCallCodec.reportedNumbers(log))
    }

    @Test
    fun aNumberIsReportedIfAnyOfItsEntriesIsReported() {
        // A log written before #57 can mix flags for one number.
        val log = listOf(call(1, number = "+972555001234"), call(2, number = "+972555001234", reported = true))
        assertEquals(setOf("+972555001234"), ScreenedCallCodec.reportedNumbers(log))
    }

    @Test
    fun reportedNumbersSkipsEntriesWithNoNumber() {
        val log = listOf(call(1, number = null, reported = true), call(2, number = null))
        assertEquals(emptySet<String>(), ScreenedCallCodec.reportedNumbers(log))
    }

    @Test
    fun aCallLoggedAfterTheReportCountsAsReported() {
        // #57: report a number, then the same number calls again.
        val reportedNumber = "+972555001234"
        var log = listOf(call(1, number = reportedNumber), call(2, number = "+972555009876"), call(3, number = null))
        log = ScreenedCallCodec.markReported(log, reportedNumber)
        // As ScreenedCallLog.append writes it: a new, unreported entry.
        log = ScreenedCallCodec.prepend(log, call(4, number = reportedNumber, reported = false))

        val newest = log.first()
        assertEquals("id-4", newest.id)
        assertFalse("the stored flag alone does not cover later entries", newest.reported)

        val reported = ScreenedCallCodec.reportedNumbers(log)
        assertEquals(setOf(reportedNumber), reported)
        // Every entry with the reported number shows Reported, the later one included.
        assertEquals(
            listOf(true, true, false, false),
            listOf("id-4", "id-1", "id-2", "id-3").map { id -> log.single { it.id == id }.number in reported },
        )
        // The rule survives a write and a reread of the log.
        val reread = ScreenedCallCodec.decode(ScreenedCallCodec.encode(log))
        assertEquals(reported, ScreenedCallCodec.reportedNumbers(reread))
    }

    @Test
    fun countBlockedSinceCountsOnlyBlockedEntriesAtOrAfterTheCutoff() {
        val since = 1_000L
        val log = listOf(
            call(1, at = since + 10),
            call(2, at = since),
            call(3, at = since - 1),
            call(4, at = since + 20, blocked = false),
            call(5, at = since + 30, reported = true),
        )
        assertEquals(3, ScreenedCallCodec.countBlockedSince(log, since))
        assertEquals(0, ScreenedCallCodec.countBlockedSince(emptyList(), since))
    }
}
