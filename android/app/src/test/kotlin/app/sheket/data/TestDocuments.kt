package app.sheket.data

import app.sheket.core.ContractFiles
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/** Blocklist documents for the data-layer tests, all derived from the read-only files in `contract/`. */
object TestDocuments {

    // Read from contract/, never copied, so regenerating the seed does not need an android change.
    val SEED_VERSION: Long get() = ContractFiles.json("seed-blocklist.json")["version"]!!.jsonPrimitive.long
    val TEST_VERSION: Long get() = ContractFiles.json("test-blocklist.json")["version"]!!.jsonPrimitive.long
    val SEED_GENERATED_AT: String get() =
        ContractFiles.json("seed-blocklist.json")["generated_at"]!!.jsonPrimitive.content
    val TEST_GENERATED_AT: String get() =
        ContractFiles.json("test-blocklist.json")["generated_at"]!!.jsonPrimitive.content

    /** In `test-blocklist.json` `call_numbers`, not in the seed. */
    const val TEST_LIST_NUMBER = "+972555001234"

    val seed: ByteArray get() = ContractFiles.bytes("seed-blocklist.json")
    val test: ByteArray get() = ContractFiles.bytes("test-blocklist.json")

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

    /** `test-blocklist.json` (newer than the seed) with `schema: 2`, which a schema 1 client must ignore. */
    val schema2: ByteArray get() = testWith("schema", JsonPrimitive(2))

    /** `test-blocklist.json` with a top-level key that schema 1 does not allow. */
    val extraKey: ByteArray get() = testWith("unexpected", JsonPrimitive(true))

    val corrupt: ByteArray = "{\"schema\": 1, \"version\": ".toByteArray(Charsets.UTF_8)
}
