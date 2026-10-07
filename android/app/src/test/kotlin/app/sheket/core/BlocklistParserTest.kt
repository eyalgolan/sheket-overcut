package app.sheket.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BlocklistParserTest {

    private val base: JsonObject = ContractFiles.json("test-blocklist.json")

    private fun parseOk(bytes: ByteArray): Blocklist {
        val result = BlocklistParser.parse(bytes)
        assertTrue("expected Ok, got $result", result is ParseResult.Ok)
        return (result as ParseResult.Ok).blocklist
    }

    private fun JsonObject.bytes(): ByteArray = toString().toByteArray(Charsets.UTF_8)

    private fun withKey(key: String, value: JsonElement): JsonObject = JsonObject(base + (key to value))

    private fun strings(vararg s: String): JsonArray = JsonArray(s.map { JsonPrimitive(it) })

    /** `sms_keywords` with the first keyword object replaced by [first]. */
    private fun keywordsWithFirst(first: JsonObject): JsonArray {
        val keywords = base.getValue("sms_keywords").jsonArray
        return JsonArray(listOf(first) + keywords.drop(1))
    }

    @Test
    fun contractListsParseAndSeedIsOlderThanTest() {
        val test = parseOk(ContractFiles.bytes("test-blocklist.json"))
        val seed = parseOk(ContractFiles.bytes("seed-blocklist.json"))
        assertEquals(1791201600L, test.version)
        assertEquals(1791149668L, seed.version)
        assertTrue("seed version must be lower than test version", seed.version < test.version)
        assertEquals(setOf("+972555001234", "+972555009876"), test.callNumbers)
        assertEquals(setOf("+97255501", "+9725552"), test.callPrefixes)
    }

    @Test
    fun reserialisedTestListParses() {
        // Control for the mutation test: the unmutated document survives the same round trip.
        parseOk(base.bytes())
    }

    @Test
    fun lowercaseTAndZWithFractionalSecondsParse() {
        val list = parseOk(withKey("generated_at", JsonPrimitive("2026-10-05t12:00:00.123z")).bytes())
        assertEquals("2026-10-05t12:00:00.123z", list.generatedAt)
    }

    @Test
    fun invalidDocumentsAreRejected() {
        val firstKeyword = base.getValue("sms_keywords").jsonArray[0].jsonObject
        assertTrue("test list needs sms_senders to mutate", base.getValue("sms_senders").jsonArray.isNotEmpty())

        val versionDouble = withKey("version", JsonPrimitive(1.0)).toString()
        assertTrue("serialised version must be 1.0: $versionDouble", "\"version\":1.0" in versionDouble)

        val validText = withKey("sms_senders", strings("ExampleX")).toString()
        val (beforeX, afterX) = validText.split("ExampleX")
        val nonUtf8 = (beforeX + "Example").toByteArray(Charsets.UTF_8) +
            byteArrayOf(0xFF.toByte()) + afterX.toByteArray(Charsets.UTF_8)

        val cases = buildList<Pair<String, ByteArray>> {
            add("schema 2" to withKey("schema", JsonPrimitive(2)).bytes())
            for (key in BlocklistParser.REQUIRED_KEYS) {
                add("missing $key" to JsonObject(base - key).bytes())
            }
            add("extra top-level key" to withKey("extra", JsonPrimitive(1)).bytes())
            add(
                "extra key in keyword object" to
                    withKey("sms_keywords", keywordsWithFirst(JsonObject(firstKeyword + ("x" to JsonPrimitive("y"))))).bytes(),
            )
            add("call_numbers national format" to withKey("call_numbers", strings("0555001234")).bytes())
            add("call_numbers trailing newline" to withKey("call_numbers", strings("+972555001234\n")).bytes())
            add("call_prefixes too short" to withKey("call_prefixes", strings("+97")).bytes())
            add("empty sms_senders entry" to withKey("sms_senders", strings("")).bytes())
            add("empty sms_allow_senders entry" to withKey("sms_allow_senders", strings("")).bytes())
            add(
                "strength medium" to
                    withKey("sms_keywords", keywordsWithFirst(JsonObject(firstKeyword + ("strength" to JsonPrimitive("medium"))))).bytes(),
            )
            add("version 1.0" to versionDouble.toByteArray(Charsets.UTF_8))
            add("generated_at without seconds" to withKey("generated_at", JsonPrimitive("2026-10-06T12:00Z")).bytes())
            add("generated_at impossible date" to withKey("generated_at", JsonPrimitive("2026-02-30T12:00:00Z")).bytes())
            add("root is an array" to "[]".toByteArray())
            add("root is a string" to "\"x\"".toByteArray())
            add("root is a number" to "1".toByteArray())
            add("non-UTF-8 bytes" to nonUtf8)
            add("malformed JSON" to base.toString().dropLast(1).toByteArray(Charsets.UTF_8))
        }

        val failures = cases.mapNotNull { (name, bytes) ->
            val result = BlocklistParser.parse(bytes)
            if (result is ParseResult.Rejected) null else "$name: expected Rejected, got $result"
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size} invalid document(s) accepted:\n" + failures.joinToString("\n"))
        }
    }

    @Test
    fun constantsMatchSchema() {
        val schema = ContractFiles.json("blocklist.schema.json")
        val properties = schema.getValue("properties").jsonObject
        fun itemPattern(key: String): String =
            properties.getValue(key).jsonObject.getValue("items").jsonObject.getValue("pattern").jsonPrimitive.content

        assertEquals(itemPattern("call_numbers"), SenderNormalizer.E164.pattern)
        assertEquals(itemPattern("call_prefixes"), BlocklistParser.CALL_PREFIX.pattern)
        assertEquals(
            schema.getValue("required").jsonArray.map { it.jsonPrimitive.content },
            BlocklistParser.REQUIRED_KEYS,
        )
    }
}
