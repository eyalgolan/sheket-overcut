package app.sheket.screening

import app.sheket.core.SenderNormalizer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * One screened incoming call in the local log (#22).
 *
 * [number] is the normalised caller number, or null when none was recorded;
 * [at] is the screening time in epoch milliseconds.
 */
data class ScreenedCall(
    val id: String,
    val number: String?,
    val at: Long,
    val blocked: Boolean,
    val reported: Boolean,
) {
    /**
     * True only if [number] is E.164. Entries whose number is not E.164 are kept
     * in the log but flagged not reportable, because the backend rejects a
     * `call` report whose sender is not E.164 (#24 uses this).
     */
    val reportable: Boolean get() = SenderNormalizer.isE164(number)
}

/**
 * Encodes and decodes the screened-call log as a UTF-8 JSON array, newest
 * first, using only the kotlinx.serialization JSON tree API. Each item is an
 * object with keys `id`, `number` (string or `null`), `at`, `blocked` and
 * `reported`.
 *
 * [decode] never throws: a missing, malformed or wrongly shaped file reads as
 * an empty log, and one bad entry rejects the whole file.
 */
object ScreenedCallCodec {

    /** Most entries kept; [prepend] drops the oldest beyond this. */
    const val MAX_ENTRIES = 200

    // RFC 8259 integer syntax, so only a true integer literal is accepted.
    private val JSON_INTEGER = Regex("-?(0|[1-9][0-9]*)")

    /** [entries] as UTF-8 JSON bytes, in the given (newest-first) order. */
    fun encode(entries: List<ScreenedCall>): ByteArray = buildJsonArray {
        for (e in entries) {
            add(
                buildJsonObject {
                    put("id", e.id)
                    put("number", e.number)
                    put("at", e.at)
                    put("blocked", e.blocked)
                    put("reported", e.reported)
                },
            )
        }
    }.toString().toByteArray(Charsets.UTF_8)

    /**
     * Decodes [bytes] written by [encode]. Null input, invalid UTF-8, invalid
     * JSON, a root that is not an array, or any entry failing the shape check
     * gives an empty list. A stored `number` is kept as is even if it is not
     * E.164. At most [MAX_ENTRIES] entries are returned.
     */
    fun decode(bytes: ByteArray?): List<ScreenedCall> {
        if (bytes == null) return emptyList()
        return try {
            val text = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
            val root = Json.parseToJsonElement(text) as? JsonArray ?: return emptyList()
            root.map { item -> toEntry(item) ?: return emptyList() }.take(MAX_ENTRIES)
        } catch (e: Exception) {
            emptyList()
        } catch (e: StackOverflowError) {
            // Deeply nested arrays in a corrupt file would overflow the recursive parser.
            emptyList()
        }
    }

    /** [entry] added as the newest; the oldest beyond [MAX_ENTRIES] is dropped. */
    fun prepend(entries: List<ScreenedCall>, entry: ScreenedCall): List<ScreenedCall> =
        (listOf(entry) + entries).take(MAX_ENTRIES)

    /** [entries] with `reported = true` on every entry whose number is [number]. */
    fun markReported(entries: List<ScreenedCall>, number: String): List<ScreenedCall> =
        entries.map { if (it.number == number) it.copy(reported = true) else it }

    /** How many entries were blocked at or after [sinceMillis]. */
    fun countBlockedSince(entries: List<ScreenedCall>, sinceMillis: Long): Int =
        entries.count { it.blocked && it.at >= sinceMillis }

    private fun toEntry(e: JsonElement): ScreenedCall? {
        if (e !is JsonObject) return null
        val id = e["id"]?.stringContent()?.takeIf { it.isNotEmpty() } ?: return null
        val numberElement = e["number"] ?: return null
        val number = if (numberElement is JsonNull) null else numberElement.stringContent() ?: return null
        val at = e["at"]?.integerContent()?.toLongOrNull() ?: return null
        val blocked = e["blocked"]?.booleanContent() ?: return null
        val reported = e["reported"]?.booleanContent() ?: return null
        return ScreenedCall(id = id, number = number, at = at, blocked = blocked, reported = reported)
    }

    /** The content of a JSON string, or null for any other element (including `null`). */
    private fun JsonElement.stringContent(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** The literal of a JSON integer, or null for strings, `null`, booleans and non-integers. */
    private fun JsonElement.integerContent(): String? = (this as? JsonPrimitive)
        ?.takeIf { it !is JsonNull && !it.isString && JSON_INTEGER.matches(it.content) }
        ?.content

    /** The value of a JSON boolean literal, or null for anything else (including the strings "true"/"false"). */
    private fun JsonElement.booleanContent(): Boolean? {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull || p.isString) return null
        return when (p.content) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }
}
