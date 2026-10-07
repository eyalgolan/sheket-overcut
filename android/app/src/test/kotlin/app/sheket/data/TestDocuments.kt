package app.sheket.data

import app.sheket.core.BlocklistParser
import app.sheket.core.CallMatcher
import app.sheket.core.ContractFiles
import app.sheket.core.ParseResult
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/** Blocklist documents for the data-layer tests, all derived from the read-only files in `contract/`. */
object TestDocuments {

    // Read from contract/, never copied. Tests that need "a list newer than the seed" use [newer], never the
    // raw test-blocklist.json, so regenerating the seed (which raises its version) does not need an android change.
    val SEED_VERSION: Long get() = ContractFiles.json("seed-blocklist.json")["version"]!!.jsonPrimitive.long
    val TEST_VERSION: Long get() = ContractFiles.json("test-blocklist.json")["version"]!!.jsonPrimitive.long
    val SEED_GENERATED_AT: String get() =
        ContractFiles.json("seed-blocklist.json")["generated_at"]!!.jsonPrimitive.content
    val TEST_GENERATED_AT: String get() =
        ContractFiles.json("test-blocklist.json")["generated_at"]!!.jsonPrimitive.content

    /**
     * The distinct entries of `test-blocklist.json` `call_numbers` and `call_prefixes`, in file order. Distinct
     * because the schema allows duplicates and the parsed list (and so [BlocklistSummary]) holds sets.
     */
    val TEST_CALL_NUMBERS: List<String> get() = testStrings("call_numbers")
    val TEST_CALL_PREFIXES: List<String> get() = testStrings("call_prefixes")

    /**
     * The first `test-blocklist.json` `call_numbers` entry that the seed does not block, by exact number or by
     * prefix. Fails if the seed blocks every one of them, because the tests then cannot tell the lists apart.
     */
    val TEST_LIST_NUMBER: String get() {
        val seedMatcher = CallMatcher((BlocklistParser.parse(seed) as ParseResult.Ok).blocklist)
        return TEST_CALL_NUMBERS.firstOrNull { !seedMatcher.shouldBlock(it) }
            ?: throw IllegalStateException(
                "contract/seed-blocklist.json blocks every call_numbers entry of contract/test-blocklist.json; " +
                    "the data tests need one test number that only the test list blocks",
            )
    }

    /** Higher than both contract lists, whichever of them is newer. */
    val NEWER_VERSION: Long get() = maxOf(SEED_VERSION, TEST_VERSION) + 1

    val seed: ByteArray get() = ContractFiles.bytes("seed-blocklist.json")
    val test: ByteArray get() = ContractFiles.bytes("test-blocklist.json")

    /** `test-blocklist.json` at [NEWER_VERSION]: always newer than the seed; contains [TEST_LIST_NUMBER]. */
    val newer: ByteArray get() = testWithVersion(NEWER_VERSION)

    /**
     * The unmodified `seed-blocklist.json` and `test-blocklist.json`, older first by their real `version`, for the
     * AC-3 version-gate tests. Fails if the two versions are equal, because the gate then has no order to test.
     */
    val contractListsOlderFirst: Pair<ByteArray, ByteArray> get() {
        val seedVersion = SEED_VERSION
        val testVersion = TEST_VERSION
        check(seedVersion != testVersion) {
            "contract/seed-blocklist.json and contract/test-blocklist.json both have version $seedVersion; " +
                "the AC-3 version-gate tests need different versions"
        }
        return if (seedVersion < testVersion) seed to test else test to seed
    }

    /** The `version` of a valid blocklist document. */
    fun versionOf(doc: ByteArray): Long =
        Json.parseToJsonElement(doc.toString(Charsets.UTF_8)).jsonObject["version"]!!.jsonPrimitive.long

    /** `test-blocklist.json` with [key] set to [value]. */
    fun testWith(key: String, value: JsonElement): ByteArray {
        val base = ContractFiles.json("test-blocklist.json")
        return JsonObject(base + (key to value)).toString().toByteArray(Charsets.UTF_8)
    }

    fun testWithVersion(version: Long): ByteArray = testWith("version", JsonPrimitive(version))

    /** `seed-blocklist.json` with a different `version`. */
    fun seedWithVersion(version: Long): ByteArray {
        val base = ContractFiles.json("seed-blocklist.json")
        return JsonObject(base + ("version" to JsonPrimitive(version))).toString().toByteArray(Charsets.UTF_8)
    }

    /** [newer] with `schema: 2`, which a schema 1 client must ignore; rejected for its schema, not its version. */
    val schema2: ByteArray get() = newerWith("schema", JsonPrimitive(2))

    /** [newer] with a top-level key that schema 1 does not allow; rejected for the key, not its version. */
    val extraKey: ByteArray get() = newerWith("unexpected", JsonPrimitive(true))

    private fun newerWith(key: String, value: JsonElement): ByteArray {
        val base = Json.parseToJsonElement(newer.toString(Charsets.UTF_8)).jsonObject
        return JsonObject(base + (key to value)).toString().toByteArray(Charsets.UTF_8)
    }

    private fun testStrings(key: String): List<String> =
        ContractFiles.json("test-blocklist.json")[key]!!.jsonArray.map { it.jsonPrimitive.content }.distinct()

    val corrupt: ByteArray = "{\"schema\": 1, \"version\": ".toByteArray(Charsets.UTF_8)
}
